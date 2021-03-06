{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE UndecidableInstances #-}
module Darcs.Test.Patch.Arbitrary.Real where
import Darcs.Test.Patch.Arbitrary.Generic
import Darcs.Test.Patch.Arbitrary.PrimV1 ()
import Darcs.Test.Patch.RepoModel

import Darcs.Witnesses.Ordered
import Darcs.Patch.Merge ( Merge(..) )
import Darcs.Patch.Patchy ( Patchy, Commute(..) )
import Darcs.Patch.Prim ( PrimPatch, anIdentity )
import Darcs.Patch.V2 ( RealPatch )
import Darcs.Patch.V2.Real ( isDuplicate )

import Test.QuickCheck
import Darcs.Test.Patch.WithState
import Darcs.Witnesses.Sealed
import Darcs.Witnesses.Eq
import Darcs.Patch.Prim ( FromPrim(..) )

#include "gadts.h"

nontrivialReals :: PrimPatch prim => (RealPatch prim :> RealPatch prim) C(x y) -> Bool
nontrivialReals = nontrivialCommute

nontrivialCommute :: Patchy p => (p :> p) C(x y) -> Bool
nontrivialCommute (x :> y) = case commute (x :> y) of
                              Just (y' :> x') -> not (y' `unsafeCompare` y) ||
                                                 not (x' `unsafeCompare` x)
                              Nothing -> False

nontrivialMergeReals :: PrimPatch prim => (RealPatch prim :\/: RealPatch prim) C(x y) -> Bool
nontrivialMergeReals = nontrivialMerge

nontrivialMerge :: (Patchy p, Merge p) => (p :\/: p) C(x y) -> Bool
nontrivialMerge (x :\/: y) = case merge (x :\/: y) of
                              y' :/\: x' -> not (y' `unsafeCompare` y) ||
                                            not (x' `unsafeCompare` x)

instance (RepoModel (ModelOf prim), ArbitraryPrim prim)
         => Arbitrary (Sealed2 (FL (RealPatch prim))) where
    arbitrary = do Sealed (WithStartState _ tree) <- arbitrary :: Gen (Sealed (WithStartState (ModelOf prim) (Tree prim)))
                   return $ unseal seal2 (flattenOne tree)

instance (RepoModel (ModelOf prim), ArbitraryPrim prim)
         => Arbitrary (Sealed2 (RealPatch prim)) where
    arbitrary = do Sealed (WithStartState _ tree) <- arbitrary :: Gen (Sealed (WithStartState (ModelOf prim) (Tree prim)))
                   case mapFL seal2 `unseal` flattenOne tree of
                     [] -> return $ seal2 $ fromPrim anIdentity
                     ps -> elements ps

notDuplicatestriple :: (RealPatch prim :> RealPatch prim :> RealPatch prim) C(x y) -> Bool
notDuplicatestriple (a :> b :> c) = not (isDuplicate a || isDuplicate b || isDuplicate c)

nontrivialTriple :: PrimPatch prim => (RealPatch prim :> RealPatch prim :> RealPatch prim) C(x y) -> Bool
nontrivialTriple (a :> b :> c) =
    case commute (a :> b) of
    Nothing -> False
    Just (b' :> a') ->
      case commute (a' :> c) of
      Nothing -> False
      Just (c'' :> a'') ->
        case commute (b :> c) of
        Nothing -> False
        Just (c' :> b'') -> (not (a `unsafeCompare` a') || not (b `unsafeCompare` b')) &&
                            (not (c' `unsafeCompare` c) || not (b'' `unsafeCompare` b)) &&
                            (not (c'' `unsafeCompare` c) || not (a'' `unsafeCompare` a'))
