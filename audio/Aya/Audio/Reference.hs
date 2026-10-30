{-# LANGUAGE BangPatterns #-}
module Aya.Audio.Reference
  ( ImpulseReference(..), referenceImpulse, referenceWithDelayReset ) where

import Data.Sequence (Seq, ViewL(..), (|>))
import qualified Data.Sequence as Seq

-- An independent realization of the restricted impulse fixture: direct-form
-- biquad recurrence and a persistent FIFO, rather than the engine's TPT states
-- and reusable ring. This deliberately does not import the optimized kernel.
data ImpulseReference = ImpulseReference
  { referenceRate :: !Int
  , referenceCutoff :: !Double
  , referenceAttack :: !Double
  , referenceRelease :: !Double
  , referenceDelayFrames :: !Int
  , referenceFeedback :: !Double
  , referenceMaster :: !Double
  } deriving (Eq,Show)

data State = State !Int !Double !Double !Double !Double !(Seq Double)

referenceImpulse :: ImpulseReference -> Int -> [(Float,Float)]
referenceImpulse specification count = samples Nothing specification count

referenceWithDelayReset :: ImpulseReference -> Int -> Int -> [(Float,Float)]
referenceWithDelayReset specification at count = samples (Just at) specification count

samples :: Maybe Int -> ImpulseReference -> Int -> [(Float,Float)]
samples resetAt specification count = walk (State 0 0 0 0 0 emptyDelay)
  where
    rate = fromIntegral (referenceRate specification)
    g = tan (pi*referenceCutoff specification/rate)
    denominator = 1+2*g+g*g
    b0 = g*g/denominator
    b1 = 2*b0
    b2 = b0
    a1 = 2*(g*g-1)/denominator
    a2 = (1-2*g+g*g)/denominator
    emptyDelay = Seq.replicate (referenceDelayFrames specification) 0
    walk (State !index !x1 !x2 !y1 !y2 !delay)
      | index >= count = []
      | otherwise =
          let input = if index == 0 then 1/(referenceAttack specification*rate) else 0
              filtered = if fromIntegral index < 1+referenceRelease specification*rate
                           then b0*input+b1*x1+b2*x2-a1*y1-a2*y2 else 0
              dry = filtered/sqrt 2
              beforeRead = if resetAt == Just index then emptyDelay else delay
              (wet,rest) = case Seq.viewl beforeRead of
                EmptyL -> (0,Seq.empty)
                first :< remaining -> (first,remaining)
              write = realToFrac (realToFrac (dry+wet*referenceFeedback specification) :: Float)
              output = realToFrac (max (-1) (min 1 ((dry+wet)*referenceMaster specification*min 1 (fromIntegral (index+1)/128))))
              next = State (index+1) input x1 filtered y1 (rest |> write)
          in (output,output) : walk next
