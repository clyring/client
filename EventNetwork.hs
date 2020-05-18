{-# LANGUAGE CPP, ImplicitParams, TemplateHaskell #-}
#include "Extensions.hs"

module EventNetwork
  (Request(..), Update(..)
  ,GameState(..), newGameState, updateGameState
  ,tickFrequency
  ,Events(..)
  ,GameParams(..), network, newGameRef, newGame, newGame'
  ) where

import Control.DeepSeq
import Reactive.Banana hiding (split)
import qualified Reactive.Banana as RB
import Reactive.Banana.Frameworks
import Text.Printf
import Data.Array.IArray
import Data.List
import Data.Maybe
import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import GHC.Generics (Generic)
import Control.Monad
import Control.Exception
import Data.Tree hiding (drawTree)
import Graphics.Rendering.Cairo
import Graphics.UI.Gtk hiding (get, Arrow, rectangle)
import qualified Graphics.UI.Gtk as Gtk
import qualified Data.Function as Function
import Data.Bifunctor
import Data.Time.Clock
import Data.AppSettings
import Data.IORef
import System.Process
import Data.Functor.Identity
import System.IO.Unsafe
import qualified Rank2
import qualified Rank2.TH

import Env
import Draw
import Base
import Notation hiding (get, set)
import Match
import GameTree
import Misc
import qualified Node
import Sharp
import Settings
import Shadow
import Colour
import Behavior
import Types

-- press and motion are filtered to be within the board before this is called; release, not
arrows :: Behavior (Array Colour Bool)
       -> Behavior Board
       -> Event Square
       -> Event Square
       -> Event Square
       -> Event ()
       -> MomentIO (Behavior [Arrow], Behavior (Maybe Arrow), Event ())
arrows visible board press release motion reset = mdo
  let (ePressNonempty, ePressEmpty) = RB.split $ ((\v b sq -> (if not (and v) || isJust (b ! sq) then Left else Right) sq)
                                                      <$> visible <*> board <@> press)
      pressFunc, pressEmptyFunc, motionFunc, releaseFunc :: [Arrow] -> Maybe Arrow -> Square -> (Maybe [Arrow], Maybe (Maybe Arrow))

      pressFunc a _ sq = (Just newArrows, Just (if sum (map arrowLength newArrows) < stepsPerMove then Just (sq, sq) else Nothing))
        where newArrows = filter ((/= sq) . fst) a
      pressEmptyFunc a _ sq | null a1 = (Nothing, Nothing)
                            | otherwise = (Just a2, Just (Just (head a1)))
        where (a1, a2) = partition ((== sq) . snd) a
      motionFunc a (Just (p, q)) sq
        | sq /= q && sum (map arrowLength ((p,sq) : a)) <= stepsPerMove
          = (Nothing, Just (Just (p, sq)))
      motionFunc _ _ _ = (Nothing, Nothing)
      releaseFunc a (Just (p,_)) sq
        | inRange boardRange sq && sq /= p && sum (map arrowLength newArrows) <= stepsPerMove
          = (Just newArrows, Just Nothing)
        where newArrows = (p,sq) : a
      releaseFunc a _ _ = (Nothing, Just Nothing)
  
      e = foldr (unionWith const) never [pressFunc <$> arr <*> la <@> ePressNonempty
                                        ,pressEmptyFunc <$> arr <*> la <@> ePressEmpty
                                        ,motionFunc <$> arr <*> la <@> motion
                                        ,releaseFunc <$> arr <*> la <@> release
                                        ]

      f (a, b) | null (fromMaybe [] a) && isNothing (join b) = Nothing
      f _ = Just ()

  arr <- stepper [] $ unionWith const ([] <$ reset) (filterJust (fst <$> e))
  la <- stepper Nothing $ unionWith const (Nothing <$ reset) (filterJust (snd <$> e))
  return (arr, la, filterJust (f <$> e))

-- verboseKill t = do
--   print t
--   killThread t

forkSeq :: NFData a => Behavior a -> MomentIO (Event a)
forkSeq b = do
  tidVar <- liftIO $ newMVar Nothing
  xVar <- liftIO newEmptyMVar
  
  (reactimate' =<<) . changes . flip fmap b $ \x -> do
    oldTid <- takeMVar tidVar
    newTid <- forkIO $ do
      result <- evaluate $ force x
      tid <- takeMVar tidVar
      tryTakeMVar xVar
      putMVar xVar result
      putMVar tidVar tid
    maybe (return ()) killThread oldTid
    putMVar tidVar $ Just newTid
    
  q <- fromPoll $ do
    a <- takeMVar tidVar
    m <- tryTakeMVar xVar
    putMVar tidVar a
    return m

  c <- changes q
  return $ filterJust $ q <@ c

data Defer a = Defer {undefer :: a} deriving (Generic, NFData)

moveSet :: Behavior Board
        -> Behavior Colour
        -> Behavior [Arrow]
        -> Behavior (Map Square Bool)
        -> Event (Square, Int)
        -> MomentIO (Behavior (Maybe MoveSet))
moveSet board player as lts eToggle = do
  let m = (\a b c d -> Defer (makeMoveSet a b c d)) <$> board <*> player <*> as <*> ((Map.keys . Map.filter id) <$> lts)
  e <- forkSeq m
  c <- changes board
  c' <- changes player
  accumB Nothing $ unions [const Nothing <$ unionWith const (void c) (void c')
                          ,const . undefer <$> e
                          ,(\col (sq, n) -> fmap (toggleCapture col sq n)) <$> player <@> eToggle
                          ]

----------------------------------------------------------------

treeMargin = 15 :: Double
treeRadius = 3 :: Double
treeXGap = 10 :: Double
treeYGap = 20 :: Double
treeMaxWidth = 50 :: Double

placeTree :: Forest a -> [Int] -> (Map Int [([Int], Double)], Double)
placeTree forest currentPos = f [([], forest)] 0 (Map.empty, 0)
  where
    sortNodes :: [([Int], Forest a)] -> [([Int], Forest a)]
    sortNodes = uncurry (++) . partition ((`isPrefixOf` currentPos) . fst)
    f :: [([Int], Forest a)] -> Int -> (Map Int [([Int], Double)], Double) -> (Map Int [([Int], Double)], Double)
    f [] _ x = x
    f nodes n (m, maxWidth) = f (nodes >>= \(ix, forest) -> sortNodes $ zipWith (\t a -> (ix ++ [a], subForest t)) forest [0..])
                                (n+1)
                                (Map.insert n offsets m, max maxWidth (width + treeMargin))
      where
        offsets = zipWith (\ix n -> (ix, n * gap + treeMargin))
                          (map fst nodes)
                          [0..]
        nGaps = fromIntegral (length nodes - 1)
        width = min treeMaxWidth (treeXGap * nGaps)
        gap = if nGaps == 0 then 0 else width / nGaps

drawTree :: (?env :: Env) => GameTree Node.SomeNode -> Map Int [([Int], Double)] -> Behavior (Render ())
drawTree gt offsets = toBehavior $ top <$> setColour Nothing [] <*> f (tree gt) []
  where
    top a b = do
      a
      drawNode treeMargin treeMargin []
      b

    f :: Forest Node.SomeNode -> [Int] -> Behavior' (Render ())
    f forest ix = fmap sequence_ $ sequenceA $ zipWith g forest [0..]
      where
        (x, y) = getPos ix
        g (Node node forest') n = h <$> setColour (Just node) (ix ++ [n]) <*> f forest' (ix ++ [n])
          where
            h a b = do
              a
              moveTo x y
              let (x2, y2) = getPos (ix ++ [n])
              lineTo x2 y2
              stroke
              drawNode x2 y2 (ix ++ [n])
              b
    getPos [] = (treeMargin, treeMargin)
    getPos ix = (fromJust (lookup ix (fromJust (Map.lookup (length ix) offsets))), treeMargin + treeYGap * fromIntegral (length ix))
    drawNode x y ix = do
      arc x y treeRadius 0 (2 * pi)
      fill
      when (ix == viewPos gt) $ do
        arc x y (treeRadius * 1.8) 0 (2 * pi)
        stroke
    setColour :: Maybe Node.SomeNode -> [Int] -> Behavior' (Render ())
    setColour node ix = (>>= flip setSourceColourAlpha alpha) . liftIO <$> colour  -- !!!!!!!!!!!
      where
        colour | ix == currentPos gt = pure (getConf currentColour)
               | ix == viewPos gt = pure (getConf viewColour)
               | otherwise = fromMaybe (return c) <$> maybe (pure Nothing) Node.nodeColour node
        c | isPrefixOf ix (currentPos gt) = RGB 0 0 0
          | otherwise = RGB 0 0 0.8
        alpha = if isPrefixOf ix (pathEnd gt) then 1 else 0.5

drawMoves :: (?env :: Env) => GameTree Node.SomeNode -> Double -> Behavior (DrawingArea -> Render ())
drawMoves gt treeWidth = toBehavior $ g <$> sequenceA (zipWith f (tail (inits (pathEnd gt))) [0..])
  where
    x = treeWidth + treeMargin
    y n = treeMargin + treeYGap * fromIntegral n
    yText n = y n + treeYGap * 0.85

    f :: [Int] -> Int -> Behavior' (Double -> Render (), Double -> Double -> Render (), String, String)
    f ix n = (\col s -> (bg1, bg2 col, moveNum n, s)) <$> Node.nodeColour this <*> Node.movelistEntry this
      where
        Just this = derefNode (tree gt) ix
        bg1 w = do
          let
            f = do
              rectangle x (y n) (w - x) treeYGap
              fill
            c = if | ix == currentPos gt -> currentColour
                   | even n -> goldColour
                   | otherwise -> silverColour
          liftIO (getConf c) >>= setSourceColour
          f
          when (ix == viewPos gt) $ do
            liftIO (getConf viewColour) >>= flip setSourceColourAlpha 0.5
            f
        bg2 col x' w = do
          c <- liftIO $ if | Just c <- col -> c
                           | even n -> toSRGB . blend 0.95 black . toColour <$> getConf goldColour
                           | otherwise -> toSRGB . blend 0.95 black . toColour <$> getConf silverColour
          setSourceColour c
          rectangle x' (y n) (w - x') treeYGap
          fill

    g :: [(Double -> Render (), Double -> Double -> Render (), String, String)] -> DrawingArea -> Render ()
    g l canvas = do
      w <- liftIO $ fromIntegral <$> widgetGetAllocatedWidth canvas
      setFontSize (treeYGap * 0.75)
      let (bg1s, bg2s, s1s, s2s) = unzip4 l
      mapM_ ($ w) bg1s
      setSourceRGB 0.8 0.8 0.8
      xs <- forM (zip s1s [0..]) $ \(s, n) -> do
        moveTo (x + treeYGap * 0.5) (yText n)
        showText s
        fst <$> getCurrentPoint
      let x' = treeMargin + max (x + 45) (maximum xs)
      mapM_ (\f -> f x' w) bg2s
      setSourceRGB 0.8 0.8 0.8
      forM_ (zip s2s [0..]) $ \(s, n) -> do
        moveTo (x' + treeYGap * 0.5) (yText n)
        showText s

mouseNode :: [Int] -> Map Int [([Int], Double)] -> Double -> (Double, Double) -> Maybe [Int]
mouseNode pathEnd offsets width (x,y)
  | x <= width + treeMargin = do
      l <- Map.lookup (round level) offsets
      let (ix, dist) = minimumBy (compare `Function.on` snd)
                                 $ map (second (\off -> sqrt ((x - off) ^ 2
                                                      + (y - (treeMargin + fromIntegral (round level) * treeYGap)) ^ 2)))
                                       l
      if dist <= 10
        then Just ix
        else Nothing
  | otherwise = let n = ceiling level in
                 if n >= 1 && n <= length pathEnd
                   then Just (take n pathEnd) else Nothing
  where
    level = (y - treeMargin) / treeYGap

----------------------------------------------------------------

data Stepper a = Stepper
  {initial :: a
  ,event :: Event a
  ,behavior :: Behavior a
  }

mkStepper :: MonadMoment m => a -> Event a -> m (Stepper a)
mkStepper x e = Stepper x e <$> stepper x e

switchStepper :: MonadMoment m => Stepper (Behavior a) -> m (Behavior a)
switchStepper Stepper{initial, event} = switchB initial event

-- deadlocks without laziness, I don't know why
instance Functor Stepper where
  fmap f ~Stepper{initial, event, behavior} = Stepper (f initial) (f <$> event) (f <$> behavior)

----------------------------------------------------------------

-- fails if pure and impure event occur together
treeAccum :: a -> Event (a -> (a, b)) -> Event (a -> MomentIO (a, c)) -> MomentIO (Stepper a, Event b, Event c)
treeAccum init pures impures = mdo
  let q1 = flip ($) <$> b <@> pures
  q2 <- execute ((flip ($)) <$> b <@> impures)
  let e = unionWith const (fst <$> q1) (fst <$> q2)
  b <- stepper init e
  return (Stepper init e b, snd <$> q1, snd <$> q2)

----------------------------------------------------------------

treeNetwork
  :: (?env :: Env)
  => Events Event
  -> Behavior Conf
  -> Event (GameTree Node.SomeNode)
  -> Event Node.SomeNode
  -> Event (GameTree Node.SomeNode -> MomentIO (GameTree Node.SomeNode, Maybe SharpProcess))
  -> Event ()
  -> Behavior Bool
  -> Event ()
  -> Behavior Bool
  -> Event ()
  -> MomentIO (Behavior (GameTree Node.SomeNode), Event (Maybe Node.SomeNode))
treeNetwork events bConf eInitialTree eMove ePlan eSharp killPlans eInput haveInput eSecond = mdo
  let
    eTreeMove = treeMove <$> killPlans <*> haveInput <*> behavior sTree <@> eMove

    eInput' = (f <$> behavior sTree) <@ eInput
      where
        f :: GameTree Node.SomeNode -> [SharpProcess]
        f gt
          | Just (Node.SomeNode n) <- viewNode gt
          , Node.CS s <- Node.content n
          = [s]
          | otherwise = []
  
--  (eTree, bTree) <- initAccum initTree
  let pures = unions [const <$> eInitialTree
                     ,(\gt -> select (if null (viewPos gt) then [] else init (viewPos gt)) gt) <$ prevE events
                     ,(\gt -> select (take (length (viewPos gt) + 1) (pathEnd gt)) gt) <$ nextE events
                     ,(\gt -> select (if length (viewPos gt) <= 2 then [] else take 2 (viewPos gt)) gt) <$ startE events
                     ,(\gt -> select (pathEnd gt) gt) <$ endE events
                     ,(\gt -> select (currentPos gt) gt) <$ currentE events
                     ,prevBranch <$ prevBranchE events
                     ,nextBranch <$ nextBranchE events
                     ,select <$> eSelect
                     ,const . (\(a,_,_) -> a) <$> eTreeMove
                     ]

  (sTree, eDel, ePauseAndToggle) <-
    let
      z :: Monad m => (b -> b -> b) -> (a -> m (a, b)) -> (a -> m (a, b)) -> a -> m (a, b)
      z k f g gt = do
        (gt', s1) <- f gt
        (gt'', s2) <- g gt'
        return (gt'', k s1 s2)
      y :: (b -> b -> b) -> (a -> (a, b)) -> (a -> (a, b)) -> a -> (a, b)
      y k f g gt = runIdentity $ z k (Identity . f) (Identity . g) gt

      fromPause e = (fmap (second ((,[]) . maybeToList)) .) <$> e
      fromToggle e = (fmap (second (([],) . maybeToList)) .) <$> e
    in treeAccum (mkGameTree [] [] [])
         (foldr (unionWith (y (++))) never
           ((((, []) .) <$> pures)
           : [deleteViewNode <$ deleteNodeE events
             ,deleteLine <$ deleteLineE events
             ,deleteAll <$ deleteAllE events
             ,deleteFromHere <$ deleteFromHereE events
             ]))
         (foldr (unionWith (z (\(a1, b1) (a2, b2) -> (a1++a2, b1++b2)))) never
           [fromPause ePlan
           ,fromPause (Node.addSharp bConf (unionWith (++) (fst <$> ePauseAndToggle) eInput') (snd <$> ePauseAndToggle) eSecond <$ eSharp)
           ,fromToggle (Node.toggleSharp <$ toggleSharpE events)
           ])

  reactimate $ mapM_ Node.killNode <$> unionWith (++) eDel ((\(_,_,a) -> a) <$> eTreeMove)

  let
    sTreePlaces = (\gt -> (gt, placeTree (tree gt) (currentPos gt))) <$> sTree   -- combined because used together in drawTree
    eSelect = filterJust $ (\(gt, (offsets, width)) -> mouseNode (pathEnd gt) offsets width) <$> behavior sTreePlaces <@> treePress events
    eClear = foldr (unionWith const) never
                   [void eInitialTree
                   ,startE events, endE events, currentE events, prevE events, nextE events, prevBranchE events, nextBranchE events, deleteNodeE events, deleteLineE events
                   ,void eSelect, void ePlan
                   ,void eSharp  -- should be filtered somewhat
                   ,void $ filterE (\(_,a,_) -> a) eTreeMove
                   ,void $ whenE ((\gt -> not (viewPos gt `isPrefixOf` currentPos gt)) <$> behavior sTree) (deleteAllE events)
                   ]

  bDrawTree <- switchStepper $ (\(gt, (offsets, _)) -> drawTree gt offsets) <$> sTreePlaces
  bDrawMoves <- switchStepper $ (\(gt, (_, width)) -> drawMoves gt width) <$> sTreePlaces

  onChanges $ get setDrawTree <$> ((\x1 x2 canvas -> do {x1; x2 canvas}) <$> bDrawTree <*> bDrawMoves)
      
  reactimate $ (\t -> do
      Gtk.set (get (treeCanvas . widgets))
              [widgetHeightRequest := round (fromIntegral (treeDepth (tree t)) * treeYGap + 2 * treeMargin)]
      a <- scrolledWindowGetVAdjustment (get (treeScrolledWindow . widgets))
      let y = treeMargin + fromIntegral (length (viewPos t)) * treeYGap
      v <- adjustmentGetValue a
      p <- adjustmentGetPageSize a
      when (y < v + 2 * treeYGap) $ Gtk.set a [adjustmentValue := y - 2 * treeYGap]
      when (y > v + p - 2 * treeYGap) $ Gtk.set a [adjustmentValue := y - p + 2 * treeYGap]
    ) <$> event sTree

  return (behavior sTree, viewNode <$> event sTree)  -- returned event stream fires too often

----------------------------------------------------------------

tickFrequency = 10 :: Int

-- onChanges b = do
--   valueBLater b >>= liftIOLater
--   reactimate' =<< changes b
onChanges = (>>= reactimate') . changes

----------------------------------------------------------------

flipSquare :: Square -> Square
flipSquare (x, y) = (boardWidth - 1 - x, boardHeight - 1 - y)

buttonAction :: Button -> Event () -> Behavior (Maybe a) -> MomentIO (Event a)
buttonAction b e x = do
  onChanges $ widgetSetSensitive b <$> (isJust <$> x)
  return $ filterJust $ x <@ e

bigClockLabel :: Int -> Int -> Bool -> String
bigClockLabel clock extra dran = "<span weight=\"bold\" foreground=\"" ++ colour ++ "\""
                                            ++ (if dran then " background=\"white\"" else "") ++ ">"
                                      ++ "<span size=\"large\">" ++ a1 ++ "</span><span size=\"xx-large\">" ++ a2 ++ "</span></span>"
                                  ++ " + " ++ showClockDuration extra
  where
    (a1, a2) = showClockDuration' clock
    colour | clock <= 10 = "red"
           | clock <= 30 = "orange"
           | otherwise = "blue"

augmentTimeUsed user minDiff (t, diff) | t == 0 = 0
                                       | otherwise = t + fromMaybe 0 (liftA2 (-) diff minDiff)
                                                       + if user then 2 else 0

timeUsed :: forall m. MonadMoment m
         => GameParams
         -> Colour
         -> Behavior (Maybe Int)
         -> Behavior Bool
         -> Behavior Bool
         -> Event Update
         -> Event ()
         -> m (Behavior Int)
timeUsed params player bMinDiff clocksRun isDran eUpdate eTick
    = fmap (liftA2 (augmentTimeUsed (isUser params ! player))
                   bMinDiff)
           timeUsed'
  where
    timeUsed' :: m (Behavior (Int, Maybe Int))
    timeUsed' = (fmap . fmap) (first (`div` tickFrequency))
                              $ accumB (0, Nothing) $ unions [whenE ((&&) <$> clocksRun <*> isDran) $ first (+1) <$ eTick
                                                             ,const <$> filterJust (f <$> isDran <@> eUpdate)
                                                             ]
      where
        f True UpdateMove{} = Just (0, Nothing)
        f _ UpdateUsed{playerUsed = Just (c, t), timeDiff} | c == player = Just (tickFrequency * t, timeDiff)
        f _ _ = Nothing

gameTimeUsed :: MonadMoment m => GameParams -> Behavior (Maybe Int) -> Behavior Bool -> Event Update -> Event () -> m (Behavior Int)
gameTimeUsed params bMinDiff clocksRun eUpdate eTick
    = fmap (liftA2 (augmentTimeUsed (or (isUser params)))
                   bMinDiff) gameTimeUsed'
  where
    gameTimeUsed' = (fmap . fmap) (first (`div` tickFrequency))
                                  $ accumB (0, Nothing) $ unions [whenE clocksRun $ first (+1) <$ eTick
                                                                 ,filterJust $ f <$> eUpdate
                                                                 ]
      where
        f UpdateUsed{gameUsed = Just t, timeDiff} = Just (const (t * tickFrequency, timeDiff))
        f _ = Nothing

data Clocks = Clocks
  {state :: Int
  ,used :: Int
  ,bigLabel :: String
  ,usedLabel :: String
  }

newClocks :: Clocks
newClocks = Clocks 0 0 "" ""

mkClocks :: TimeControl -> Bool -> Int -> Int -> Clocks
mkClocks tc run state used
    = Clocks{state, used
            ,bigLabel = bigClockLabel clock extra run
            ,usedLabel = "Move time: " ++ showClockDuration used
            }
  where
    clock = timeAvailable tc state - used
    extra = state + increment tc - timeAvailable tc state

-- forall m so that it can be used inside execute (no reactimate)
clocks :: forall m. MonadMoment m
  => Behavior GameState
  -> Event Update
  -> Event ()
  -> GameParams
  -> m (Colour -> m (Behavior Clocks), Behavior String)
clocks gameState eUpdate eTick params = do
  let
    eDiff = filterJust (f <$> eUpdate)
      where f UpdateUsed{timeDiff} = timeDiff
            f _ = Nothing

    -- attempt to account for lag suggested by lightvector in chat
  bMinDiff <- accumB Nothing $ (\d -> Just . maybe d (min d)) <$> eDiff

  let
    isDran player = ((== player) . posToMove . position) <$> gameState
    clocksRun = (\gs -> started gs && isNothing (result gs)) <$> gameState

    clockState :: Colour -> m (Behavior Int)
    clockState player = accumB (initialReserve (timeControl params))
                               $ filterJust (f <$> isDran player <@> eUpdate)
      where
        f True (UpdateMove (_,x)) = updateReserve (timeControl params) <$> x
        f _ (UpdateClock (c,t)) | c == player = Just (const t)
        f _ _ = Nothing


    gameLabel n = case gameLimit (timeControl params) of
      Left 0 -> "No game limit"
      Right 0 -> "No game limit"
      Left l -> showClockDuration $ l - n
      Right l -> printf "Game limit: %d moves" l

  gUsed <- gameTimeUsed params bMinDiff clocksRun eUpdate eTick
  
  return (\player -> liftA2 (liftA3 (mkClocks (timeControl params))
                                    (liftA2 (&&) clocksRun (isDran player)))
                            (clockState player)
                            (timeUsed params player bMinDiff clocksRun (isDran player) eUpdate eTick),
          gameLabel <$> gUsed)

------------------------------------------------------------------------------------------------

reactimateSwitch :: Event (Behavior (IO ())) -> MomentIO ()
reactimateSwitch = switchB (pure undefined) >=> changes >=> reactimate'

----------------------------------------------------------------

nextMove
  :: (?env :: Env)
  => Behavior (Array Colour Bool)
  -> Behavior Position
  -> Behavior ShadowBoard
  -> Behavior (Maybe MoveSet)
  -> MomentIO (Behavior (Maybe (GenMove, Position)))
nextMove visible view shadow bMoveSet = do
  let
    f :: Position -> Maybe MoveSet -> ShadowBoard -> Array Colour Bool -> (String, Maybe (GenMove, Position))
    f pos mms sb v
      | posSetupPhase pos && fullShadow sb
        = g $ Left [(sq, piece) | (sq, Just (piece, _)) <- assocs (realiseShadow (posToMove pos) sb)]
      | not (posSetupPhase pos)
      , Just ms <- mms
        = case currentMove ms of
           Nothing -> ("Move is ambiguous", Nothing)
           Just m -> g (Right m)
      | otherwise = ("", Nothing)
      where g move = either (\s -> ("<span foreground=\"red\">Illegal move (" ++ s ++ ")</span>", Nothing))
                            (\pos' -> (either (const "") (\m -> if (v ! posToMove pos) then show m else "[Move hidden]") move,
                                       Just (move, pos')))
                            $ playGenMove pos move
    b = f <$> view <*> bMoveSet <*> shadow <*> visible

  onChanges $ labelSetMarkup (get (moveLabel . widgets)) . fst <$> b

  return (snd <$> b)

----------------------------------------------------------------

-- includes draw board
input
  :: (?env :: Env)
  => Events Event
  -> Behavior (Array Colour Bool)
  -> Behavior Bool
  -> Event ()
  -> Behavior Bool
  -> Behavior Conf
  -> Event (Maybe Node.SomeNode)
  -> MomentIO (Behavior (Maybe (GenMove, Position)), Event (), Behavior Bool) -- nextMove, eInput, haveInput
input events visible flipped eClear flash bConf eNode = mdo
  let
    squareMap = (\f -> if f then flipSquare else id) <$> flipped
    setup = posSetupPhase <$> view

  (eArrowLeft, eSetupToggle, eToggleCapture) <- do
    let
      (e1, eLeft') = RB.split $ (\b x -> if b then Left (fst x) else Right x)
                                    <$> setup <@> (first <$> squareMap <@> leftPress events)

      f :: Array Colour Bool -> Maybe MoveSet -> (Square, (Double, Double)) -> Either (Square, Int) Square
      f v (Just ms) (sq, x)
        | Just (m, o) <- Map.lookup sq (captures ms)
        , Just i <- smallSquare x
        , j <- i - length (filter ((v !) . fst) m)
        , j >= 0 && j < length o
          = Left (sq, j)
      f _ _ (sq, _) = Right sq
      
      (e2, e3) = RB.split $ f <$> visible <*> bMoveSet <@> eLeft'
    return (e3, e1, e2)

  view <- switchB (pure newPosition) (toBehavior . Node.position <$> eNode)

  (bArrows, liveArrow, eInput) <- do
    arrows visible (posBoard <$> view) eArrowLeft (squareMap <@> release events) (squareMap <@> motion events) eClear

  liveTraps <- do
    let empty = Map.fromList (map (,False) trapSquares)
    accumB empty $ unions [const empty <$ eClear
                          ,(\sq -> Map.mapWithKey (\trap x -> if trap == sq then not x else x))
                              <$> (squareMap <@> rightPress events)
                          ]

  shadow <- do
    accumB newShadowBoard $ unions $ [const newShadowBoard <$ eClear
                                     ,flipShadowSquare <$> (posToMove <$> view) <@> eSetupToggle
                                     ] ++ zipWith (\i e -> (\(ShadowBoard b r c)
                                                               -> ShadowBoard b r (if r ! i == 0 then c else i)) <$ e)
                                                  [0..] (reverse (setupIconsE events))

  let haveInput = (\as la lt s -> not (null as) || isJust la || or lt || not (emptyShadow s))
                     <$> bArrows <*> liveArrow <*> liveTraps <*> shadow

  bMoveSet <- moveSet (posBoard <$> view) (posToMove <$> view) bArrows liveTraps eToggleCapture

  ----------------------------------------------------------------

  let
    f :: Maybe Node.SomeNode -> Behavior (IO ())
    f node = get setDrawBoard
               <$> (toBehavior (drawNode node) <*> shadow <*> ((\as la -> maybe as (:as) la) <$> bArrows <*> liveArrow) <*> liveTraps <*> bMoveSet <*> visible <*> squareMap <*> flash <*> bConf)
    in reactimateSwitch $ f <$> eNode

  let setupLabelsB = (\(ShadowBoard _ remaining _) -> map show $ elems remaining) <$> shadow
    in onChanges $ zipWithM_ labelSetText (reverse (get setupLabels)) <$> setupLabelsB

  
  let f pos (ShadowBoard _ _ current) v conf = do
          zipWithM_ ($) (if posSetupPhase pos then [widgetShow, widgetHide] else [widgetHide, widgetShow])
                        [get (setupGrid . widgets), get (captureGrid . widgets)]
          if posSetupPhase pos then zipWithM_ g (reverse (get setDrawSetupIcons)) [0 .. length pieceInfo - 1]
                               else get setDrawCapture (drawCaptures (posBoard pos) v (get icons Map.! getSetting' conf pieceSet))
        where
          g set i = set $ drawSetupIcon (i == current) (get icons Map.! getSetting' conf pieceSet ! (posToMove pos, i))
    in onChanges $ f <$> view <*> shadow <*> visible <*> bConf

  let f pos v | and v = printf "HarLog: %+.2f" $ harlog $ posBoard pos
              | otherwise = ""
    in onChanges $ labelSetText (get (harlogLabel . widgets)) <$> (f <$> view <*> visible)

  ----------------------------------------------------------------

  bMove <- nextMove visible view shadow bMoveSet

  return (bMove, eInput, haveInput)

------------------------------------------------------------------------------------------------

roundTripTimes :: Eq b => Event b -> Event b -> MomentIO (Event NominalDiffTime)
roundTripTimes x y = do
  let f a = do
        t <- getCurrentTime
        return (a, t)
  e <- mapEventIO f x
  pending <- accumB [] $ unions [(:) <$> e
                                ,(\b -> filter ((/= b) . fst)) <$> y
                                ]
  let diffTime t = do
        t' <- getCurrentTime
        return $ diffUTCTime t' t
  mapEventIO diffTime $ filterJust $ (\p b -> snd <$> find ((== b) . fst) p) <$> pending <@> y

splitEventIO :: Event (IO a) -> MomentIO (Event (IO ()), Event a)
splitEventIO e = do
  (e', fire) <- newEvent
  return ((>>= fire) <$> e, e')

unzipF :: Functor f => f (a, b) -> (f a, f b)
unzipF x = (fst <$> x, snd <$> x)

mapSend :: Eq a => [Event Request] -> Either (Request -> IO ()) (Request -> IO a, MomentIO (Event a)) -> MomentIO (Event (IO ()), [Behavior Bool])
mapSend es (Left f) = return (foldr (unionWith (>>)) never (fmap f <$> es)
                             ,map (const (pure False)) es)
mapSend es (Right (request, x)) = do
  eResponse <- x
  (eios, eas) <- unzip <$> mapM splitEventIO (fmap request <$> es)
  let
    g a (Just b) | a == b = Nothing
    g _ b = b
    f e = fmap (fmap isJust) $ accumB Nothing $ unions [const . Just <$> e
                                                       ,g <$> eResponse]
  bs <- mapM f eas
  ets <- mapM (\e -> fmap print <$> roundTripTimes e eResponse) eas

  return (foldr (unionWith (>>)) never (eios ++ ets), bs)
  
requests
  :: (?env :: Env)
  => Events Event
  -> Event NewGame
  -> Behavior GameState
  -> Behavior (GameTree Node.SomeNode)
  -> Behavior (Maybe (GenMove, Position))
  -> Behavior GameParams
  -> MomentIO ()
requests events eNewGame gameState bTree nextMove params = mdo
  let
    sendMove :: Behavior (Maybe GenMove)
    sendMove = g <$> (posToMove . position <$> gameState) <*> bTree <*> (fmap fst <$> nextMove) <*> sendStatus <*> params
      where
        g _ _ _ True _ = Nothing
        g c gt m _ p | not (isUser p ! c) = Nothing
                     | otherwise = case stripPrefix (currentPos gt) (viewPos gt) of
                         Just [] -> m
                         Just (x:_) -> Node.regularMove =<< derefNode (tree gt) (currentPos gt ++ [x])
                         _ -> Nothing

    bStartSend = f <$> gameState <*> sendMove
      where
        f _ (Just m) = Just (Just m)
        f gs _ | not (started gs) = Just Nothing
               | otherwise = Nothing

  eStartSend <- buttonAction (get (sendButton . widgets)) (sendE events) bStartSend

  let
    eStart = RequestStart <$ whenE ((\gs p -> not (started gs) && isUser p ! Gold) <$> gameState <*> params) eStartSend
    eSend = RequestMove <$> filterJust eStartSend

  eResign <- buttonAction (get (resignButton . widgets)) (resignE events) (fmap RequestResign <$> defaultColour)

  (eeio, ebs) <- unzipF <$> execute ((\NewGame{request} -> mapSend [eStart, eSend, eResign] request) <$> eNewGame)
  switchE eeio >>= reactimate
  
  startStatus <- switchB (pure False) ((!! 0) <$> ebs)
  sendStatus <- switchB (pure False) ((!! 1) <$> ebs)
  resignStatus <- switchB (pure False) ((!! 2) <$> ebs)

  let f _ True _ = "Starting"
      f _ _ True = "Sending"
      f False _ _ = "Start"
      f _ _ _ = "Send"
    in onChanges $ buttonSetLabel (get (sendButton . widgets)) <$> (f <$> (started <$> gameState) <*> startStatus <*> sendStatus)

  let defaultColour = (\p -> find (isUser p !) [Gold, Silver]) <$> params

  onChanges $ buttonSetLabel (get (resignButton . widgets)) . (\b -> if b then "Resigning" else "Resign") <$> resignStatus

------------------------------------------------------------------------------------------------
  
-- includes clocks
move :: Behavior GameState
     -> Event Update
     -> Behavior (GameTree Node.SomeNode)
     -> Array Colour (Behavior Clocks)
     -> Event Node.SomeNode
move gameState eUpdate bTree bClocks = eMove
  where
    dranClock = (!) <$> sequenceA bClocks <*> (posToMove . position <$> gameState)
    
    eMoveTime :: Event (GenMove, Maybe Int)
    eMoveTime = filterJust (f <$> dranClock <@> eUpdate)
      where
        f _ (UpdateMove (m, Just t)) = Just (m, Just t)
        f cl (UpdateMove (m, Nothing)) = Just (m, g cl)
        f _ _ = Nothing
        g cl | used cl == 0 = Nothing
             | otherwise = Just $ used cl

    -- problem: redundant calls to playGenMove
    -- not using gameState is probably bad
    -- shouldn't use Node stuff
    eMove = fromMaybe (error "Current node not regular")
        <$> (f <$> ((\gt -> derefNode (tree gt) (currentPos gt)) <$> bTree) <@> eMoveTime)
      where
        f node (move, t) = Node.useRegular' node $ \r -> case playGenMove (Node.regularPosition r) move of
          Left e -> error e
          Right p -> Node.SomeNode $ Node.mkRegularNode r move p ((,0) <$> t)

doClocks
  :: (?env :: Env)
  => Event NewGame
  -> Behavior GameParams
  -> Behavior GameState
  -> Event Update
  -> Event ()
  -> Behavior Bool
  -> MomentIO (Array Colour (Behavior Clocks))
doClocks eNewGame bParams gameState eUpdate eTick flipped = do
  e <- execute $ clocks gameState eUpdate eTick . params <$> eNewGame
  let
    eMkClocks = fst <$> e :: Event (Colour -> MomentIO (Behavior Clocks))
    eGameClockLabel = snd <$> e :: Event (Behavior String)
  bClocks <- sequenceA $ mapColourArray (\c -> execute (($ c) <$> eMkClocks) >>= switchB (pure newClocks))
  gameClockLabel <- switchB (pure "") eGameClockLabel

  -- note assumption that player names do not contain markup
  forM_ [Gold, Silver] $ \c -> do
    let nameString = (\p -> names p ! c ++ maybe "" (printf " (%d)") (ratings p ! c)) <$> bParams
    sequence_ $ zipWith3 (\top bottom s -> onChanges $ (\f s -> labelSetMarkup (if (c == Gold) == f then get (top . widgets) else get (bottom . widgets)) s)
                                                           <$> flipped <*> s)
                         [topPlayer, topClock, topUsedClock]
                         [bottomPlayer, bottomClock, bottomUsedClock]
                         [nameString, bigLabel <$> bClocks ! c, usedLabel <$> bClocks ! c]

  onChanges $ labelSetText (get (gameClock . widgets)) <$> gameClockLabel

  return bClocks

------------------------------------------------------------------------------------------------

zipB :: Behavior a -> MomentIO (Event (a, a))
zipB b = do
  (e, h) <- newEvent
  c <- changes b
  reactimate' $ (\b c -> h <$> ((b,) <$> c)) <$> b <@> c
  return e

eFlash :: Behavior GameParams -> Behavior Clocks -> Behavior Conf -> MomentIO (Event ())
eFlash params clocks bConf = do
  e <- zipB ((\p cl -> timeAvailable (timeControl p) (state cl) - used cl) <$> params <*> clocks)
  return $ void $ filterApply ((\c (old, new) -> isJust (find (\n -> new <= n && old > n) (fromMaybe [] (getSetting' c flashTimes)))) <$> bConf) e

network :: (?env :: Env) => Events AddHandler -> MomentIO ()
network ahs = mdo
  events <- Rank2.traverse fromAddHandler ahs

  do
    b <- stepper (return ()) (cleanup <$> (newGameE events))
    reactimate $ ((>> killSharps) <$> b) <@ (newGameE events)

  bParams <- stepper emptyGameParams (params <$> (newGameE events))

  (bGameState, eUpdate) <- do
    e <- execute (updates <$> (newGameE events))
    x <- switchB (pure newGameState) (fst <$> e)
    y <- switchE (snd <$> e)
    return (x, y)

  bConf <- do
    conf <- liftIO $ readTVarIO (get conf)
    stepper conf (confE events)

  bFlipped <- do
    let initialSide conf game | getSetting' conf viewMySide = fromMaybe Gold $ find (isUser (params game) !) [Gold, Silver]
                              | otherwise = Gold
    accumB False $ unions [(\c g -> const (initialSide c g == Silver)) <$> bConf <@> (newGameE events)
                          ,not <$ flipE events
                          ]

  bVisible <- do
    bBlind <- stepper (True, True) (blindMode events)
    return $ (\(seeFriendly, seeEnemy) params -> mapColourArray (\c -> if isUser params ! c then seeFriendly else seeEnemy))
                <$> bBlind <*> bParams

  (bNextMove, eInput, haveInput) <- input events bVisible bFlipped eClear flash bConf eNode

  requests events (newGameE events) bGameState bTree bNextMove bParams

  bClocks <- doClocks (newGameE events) bParams bGameState eUpdate (tick events) bFlipped

  flash <- do
    eFlash' <- fmap (foldr (unionWith const) never) $ forM [Gold, Silver] $ \c ->
      whenE ((\p -> isUser p ! c) <$> bParams)
        <$> eFlash bParams (bClocks ! c) bConf
    flashCountdown <- accumB 0 $ unions [const 3 <$ eFlash'
                                       ,max 0 . subtract 1 <$ tick events
                                       ]
    return $ (> 0) <$> flashCountdown

  let
    eMove = move bGameState eUpdate bTree bClocks

    ePlanFunc = filterJust (f <$> bConf <*> bNextMove <@ planE events)
      where
        f c x
          | getSetting' c enablePlans
          = (\(m, p) -> Node.addFromRegular (\r -> Just (return (Node.SomeNode (Node.mkRegularNode r m p Nothing))))) <$> x
          | otherwise = Nothing

  eSecond <- do
    bTicks <- accumB 0 ((+ 1) <$ tick events)
    return $ whenE ((== 0) . (`mod` tickFrequency) <$> bTicks) (tick events)

  let eSharp = whenE ((\gs p -> not (or (isUser p)) || isJust (result gs)) <$> bGameState <*> bParams) (sharpE events)

  -- eNode includes (newGameE events)
  (bTree, eNode) <- mdo
    let
      f t = mkGameTree t initialPos (take 2 initialPos)
        where initialPos = replicate (leftDepth t) 0
      user = (\gt p -> isUser p ! Node.toMove (viewNode gt)) <$> bTree <*> bParams
    treeNetwork events
                bConf
                (f . initialTree <$> (newGameE events))
                eMove
                ePlanFunc
                eSharp
                (flip getSetting' killPlans <$> bConf)
                eInput
                (liftA2 (&&) haveInput (not <$> user))
                eSecond

  let eClear = unionWith const (void eNode) (clearE events)

  let f gs params = printf "%s (%s)" (show (timeControl params)) (if rated params then "rated" else "unrated")
                     ++ maybe "" (\(c,r) -> printf " | %s won (%s)" (show c) (show r)) (result gs)
    in onChanges $ labelSetText (get (gameLabel . widgets)) <$> (f <$> bGameState <*> bParams)

    -- TODO: move number, other notations, multiple moves
  do
    bCopy <- switchB (pure undefined) $ toBehavior . fmap (maybe "" showGenMove) . Node.getMove <$> eNode
    let f s = clipboardGet selectionClipboard >>= flip clipboardSetText s
      in reactimate $ f <$> (bCopy <@ copyMovelistE events)

------------------------------------------------------------------------------------------------

newGameRef = unsafePerformIO $ newIORef undefined

newGameEither
  :: Eq a
  => GameParams
  -> Forest Node.SomeNode
  -> Either (Request -> IO ()) (Request -> IO a, MomentIO (Event a))
  -> MomentIO (Behavior GameState, Event Update)
  -> IO ()
  -> IO ()
newGameEither params initialTree request updates cleanup = do
  f <- readIORef newGameRef
  f NewGame{..}

newGame params initialTree request response updates cleanup
  = newGameEither params initialTree (Right (request, response)) updates cleanup

newGame' params initialTree request updates cleanup
  = newGameEither @() params initialTree (Left request) updates cleanup
