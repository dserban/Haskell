-- TODO: Remove these warning disabling flags...
{-# OPTIONS_GHC -w #-}
{-# LANGUAGE MultiParamTypeClasses, OverloadedStrings #-}
module Darcs.Test.Patch.Arbitrary.PrimV3 where

import qualified Darcs.Test.Patch.Arbitrary.Generic as T
     ( commuteTripleFromTree, commutePairFromTree, commutePairFromTWFP
     , mergePairFromTree, mergePairFromTWFP
     , patchFromTree )
import Darcs.Test.Patch.Arbitrary.Generic
import Darcs.Test.Patch.RepoModel

import Control.Monad ( liftM )
import Test.QuickCheck
import Darcs.Test.Patch.WithState
import Darcs.Witnesses.Sealed
import Darcs.Witnesses.Eq
import Darcs.Witnesses.Unsafe
import Darcs.Witnesses.Ordered
-- import Darcs.Witnesses.Show
import Darcs.Patch.Prim.V3 ()
import Darcs.Patch.Prim.V3.Core ( Prim(..), Location, Hunk(..), UUID(..) )
import Darcs.Patch.RepoPatch ( RepoPatch )

import Darcs.Test.Patch.V3Model
import Darcs.Test.Util.QuickCheck ( alpha, notIn, maybeOf )

import Darcs.Commands.Replace ( defaultToks )
import Darcs.Patch.Prim

import Control.Applicative ( (<$>) )
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString as BS
import Data.Maybe ( isJust )
import qualified Data.Map as M
import Storage.Hashed.Hash( Hash(..) )

#include "gadts.h"
#include "impossible.h"

patchFromTree :: (RepoPatch p, PrimOf p ~ Prim) => (FORALL(y z) p C(y z) -> t) -> WithStartState V3Model (Tree Prim) C(x) -> t
patchFromTree = T.patchFromTree

mergePairFromTree :: (RepoPatch p, PrimOf p ~ Prim) => (FORALL(y z) (p :\/: p) C(y z) -> t) -> WithStartState V3Model (Tree Prim) C(x) -> t
mergePairFromTree = T.mergePairFromTree

mergePairFromTWFP :: (RepoPatch p, PrimOf p ~ Prim) => (FORALL(y z) (p :\/: p) C(y z) -> t) -> WithStartState V3Model (TreeWithFlattenPos Prim) C(x) -> t
mergePairFromTWFP = T.mergePairFromTWFP

commutePairFromTWFP :: (RepoPatch p, PrimOf p ~ Prim) => (FORALL(y z) (p :> p) C(y z) -> t) -> WithStartState V3Model (TreeWithFlattenPos Prim) C(x) -> t
commutePairFromTWFP = T.commutePairFromTWFP

commutePairFromTree :: (RepoPatch p, PrimOf p ~ Prim) => (FORALL(y z) (p :> p) C(y z) -> t) -> WithStartState V3Model (Tree Prim) C(x) -> t
commutePairFromTree = T.commutePairFromTree

commuteTripleFromTree :: (RepoPatch p, PrimOf p ~ Prim) => (FORALL(y z) (p :> p :> p) C(y z) -> t) -> WithStartState V3Model (Tree Prim) C(x) -> t
commuteTripleFromTree = T.commuteTripleFromTree

type instance ModelOf Prim = V3Model
instance ArbitraryPrim Prim

hunkIdentity (Hunk _ old new) | old == new = unsafeCoerceP IsEq
hunkIdentity _ = NotEq

instance NullPatch Prim where
  nullPatch (BinaryHunk _ x) = hunkIdentity x
  nullPatch (TextHunk _ x) = hunkIdentity x
  nullPatch _ = NotEq

instance Arbitrary (Sealed2 (FL (WithState V3Model Prim))) where
  arbitrary = do repo <- ourSmallRepo
                 liftM (unseal (seal2 . wesPatch)) $ arbitraryState repo

-- instance Show1 (TreeWithFlattenPos Prim) where
--   showDict1 = ShowDictClass

-- WithState and propFail are handy for debugging arbitrary code
propFail :: Int -> Tree Prim C(x) -> Bool
propFail n xs = sizeTree xs < n

----------------------------------------------------------------------
-- * QuickCheck generators

aHunk :: FORALL(x y) BS.ByteString -> Gen (Hunk C(x y))
aHunk content
 = sized $ \n ->
     do pos <- choose (0, BS.length content)
        let prefixLen = pos
            restLen   = BS.length content - prefixLen
        oldLen <- frequency
                      [ (75, choose (0, min restLen n))
                      , (25, choose (0, min 10 restLen))
                      ]
        let nonempty x = if oldLen /= 0 then x else 0
        newLen <- frequency
                      [ ( 54, choose (1,min 1 n) )
                      , ( nonempty 42, choose (1,min 1 oldLen) )
                      , ( nonempty 2, return oldLen )
                      , ( nonempty 2, return 0 )
                      ]
        new <- BS.concat <$> vectorOf newLen aLine
        let old = BS.take oldLen $ BS.drop prefixLen $ content
        return $ Hunk pos old new

aTextHunk :: FORALL (x y) (UUID, Object Fail) -> Gen (Prim C(x y))
aTextHunk (uuid, (Blob text _)) =
  do hunk <- aHunk (unFail text)
     return $ TextHunk uuid hunk

aManifest :: FORALL (x y) UUID -> Location -> Object Fail -> Gen (Prim C(x y))
aManifest uuid loc (Directory dir) =
  do newFilename <- aFilename `notIn` (M.keys dir)
     return $ Manifest uuid loc

aDemanifest :: FORALL (x y) UUID -> Location -> Gen (Prim C(x y))
aDemanifest uuid loc = return $ Demanifest uuid loc

-- | Generates any type of 'Prim' patch, except binary and setpref patches.
aPrim :: FORALL(x y) V3Model C(x) -> Gen (WithEndState V3Model (Prim C(x)) C(y))
aPrim repo
  = do mbFile <- maybeOf repoFiles
       mbDir <- maybeOf repoDirs
       mbExisting <- maybeOf $ repoObjects repo
       mbManifested <- maybeOf manifested
       fresh <- anUUID
       filename <- aFilename
       dir  <- elements (rootDir:repoDirs)
       mbOtherDir <- maybeOf repoDirs
       let whenfile x = if isJust mbFile then x else 0
           whendir x = if isJust mbDir then x else 0
           whenexisting x = if isJust mbExisting then x else 0
           whenmanifested x = if isJust mbManifested then x else 0
       patch <- frequency
                  [ ( whenfile 12, aTextHunk $ fromJust mbFile )
                  , ( 2, aTextHunk (fresh, Blob (return "") NoHash) ) -- create an empty thing
                  , ( whenexisting (whendir 2), -- manifest an existing object
                      aManifest (fst $ fromJust mbExisting)
                                (fst $ fromJust mbDir, filename)
                                (snd $ fromJust mbDir))
                  , ( whenmanifested 2, uncurry aDemanifest $ fromJust mbManifested )
                    -- TODO: demanifest
                  ]
       let repo' = unFail $ repoApply repo patch
       return $ WithEndState patch repo'
  where
      manifested = [ (id, (dirid, name)) | (dirid, Directory dir) <- repoDirs
                                         , (name, id) <- M.toList dir ]
      repoFiles = [ (id, Blob x y) | (id, Blob x y) <- repoObjects repo ]
      repoDirs  = [ (id, Directory x) | (id, Directory x) <- repoObjects repo ]
      rootDir   = (UUID "ROOT", root repo)

----------------------------------------------------------------------
-- *** Pairs of primitive patches

-- Try to generate commutable pairs of hunks
hunkPair :: FORALL(x y) (UUID, Object Fail) -> Gen ((Prim :> Prim) C(x y))
hunkPair (uuid, (Blob file _)) =
  do h1@(Hunk l1 old1 new1) <- aHunk (unFail file)
     (delta, content') <- selectChunk h1 (unFail file)
     Hunk l2' old2 new2 <- aHunk content'
     let l2 = l2'+delta
     return (TextHunk uuid (Hunk l1 old1 new1) :> TextHunk uuid (Hunk l2 old2 new2))
  where
     selectChunk (Hunk l old new) content = elements [prefix, suffix]
       where start = l - 1
             prefix = (0, BS.take start content)
             suffix = (start + BS.length new, BS.drop (start + BS.length old) content)
     selectChunk _ _ = impossible

aPrimPair :: FORALL(x y) V3Model C(x) -> Gen (WithEndState V3Model ((Prim :> Prim) C(x)) C(y))
aPrimPair repo
  = do mbFile <- maybeOf repoFiles
       frequency
          [ ( if isJust mbFile then 1 else 0
            , do p1 :> p2 <- hunkPair $ fromJust mbFile
                 let repo'  = unFail $ repoApply repo  p1
                     repo'' = unFail $ repoApply repo' p2
                 return $ WithEndState (p1 :> p2) repo''
            )
          , ( 1
            , do Sealed wesP <- arbitraryState repo
                 return $ unsafeCoerceP1 wesP
            )
          ]
  where
      repoFiles = [ (id, Blob x y) | (id, Blob x y) <- repoObjects repo ]

----------------------------------------------------------------------
-- Arbitrary instances

ourSmallRepo :: Gen (V3Model C(x))
ourSmallRepo = aSmallRepo

instance ArbitraryState V3Model Prim where
  arbitraryState s = seal <$> aPrim s


instance Arbitrary (Sealed2 Prim) where
  arbitrary = makeS2Gen ourSmallRepo

instance Arbitrary (Sealed (Prim x)) where
  arbitrary = makeSGen ourSmallRepo

instance Arbitrary (Sealed2 (Prim :> Prim)) where
  arbitrary = do repo <- ourSmallRepo
                 WithEndState pp _ <- aPrimPair repo
                 return $ seal2 pp

instance Arbitrary (Sealed ((Prim :> Prim) C(a))) where
  arbitrary = do repo <- ourSmallRepo
                 WithEndState pp _ <- aPrimPair repo
                 return $ seal pp

instance Arbitrary (Sealed2 (Prim :> Prim :> Prim)) where
  arbitrary = makeS2Gen ourSmallRepo

instance Arbitrary (Sealed ((Prim :> Prim :> Prim) a)) where
  arbitrary = makeSGen ourSmallRepo

instance Arbitrary (Sealed2 (FL Prim)) where
  arbitrary = makeS2Gen ourSmallRepo

instance Arbitrary (Sealed ((FL Prim) C(a))) where
  arbitrary = makeSGen ourSmallRepo

instance Arbitrary (Sealed2 (FL Prim :> FL Prim)) where
  arbitrary = makeS2Gen ourSmallRepo

instance Arbitrary (Sealed ((FL Prim :> FL Prim) C(a))) where
  arbitrary = makeSGen ourSmallRepo

instance Arbitrary (Sealed2 (WithState V3Model Prim)) where
  arbitrary = makeWS2Gen ourSmallRepo

instance Arbitrary (Sealed (WithState V3Model Prim C(a))) where
  arbitrary = makeWSGen ourSmallRepo

instance Arbitrary (Sealed (WithState V3Model (FL Prim) C(a))) where
  arbitrary = makeWSGen ourSmallRepo

instance Arbitrary (Sealed2 (WithState V3Model (Prim :> Prim))) where
  arbitrary = do repo <- ourSmallRepo
                 WithEndState pp repo' <- aPrimPair repo
                 return $ seal2 $ WithState repo pp repo'

instance Arbitrary (Sealed (WithState V3Model (Prim :> Prim) a)) where
  arbitrary = do repo <- ourSmallRepo
                 WithEndState pp repo' <- aPrimPair repo
                 return $ seal $ WithState repo pp repo'


instance Arbitrary (Sealed2 (WithState V3Model (FL Prim))) where
  arbitrary = makeWS2Gen ourSmallRepo

instance Arbitrary (Sealed2 (WithState V3Model (FL Prim :> FL Prim))) where
  arbitrary = makeWS2Gen ourSmallRepo

instance Arbitrary (Sealed (WithState V3Model (FL Prim :> FL Prim) a)) where
  arbitrary = makeWSGen ourSmallRepo
