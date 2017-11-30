module Data.Functor.Classes.Generic.Spec where

import Data.Functor.Classes.Generic
import Data.Functor.Listable
import GHC.Generics
import Test.Hspec
import Test.Hspec.LeanCheck

spec :: Spec
spec = parallel $ do
  describe "Eq1" $ do
    describe "genericLiftEq" $ do
      prop "equivalent to derived (==) for product types" $
        \ a b -> genericLiftEq (==) a b `shouldBe` a == (b :: Product Int)

      prop "equivalent to derived (==) for sum types" $
        \ a b -> genericLiftEq (==) a b `shouldBe` a == (b :: Sum Int)

      prop "equivalent to derived (==) for recursive types" $
        \ a b -> genericLiftEq (==) a b `shouldBe` a == (b :: Tree Int)

  describe "Ord1" $ do
    describe "genericLiftCompare" $ do
      prop "equivalent to derived compare for product types" $
        \ a b -> genericLiftCompare compare a b `shouldBe` compare a (b :: Product Int)

      prop "equivalent to derived compare for sum types" $
        \ a b -> genericLiftCompare compare a b `shouldBe` compare a (b :: Sum Int)

      prop "equivalent to derived compare for recursive types" $
        \ a b -> genericLiftCompare compare a b `shouldBe` compare a (b :: Tree Int)


data Product a = Product a a a
  deriving (Eq, Generic1, Ord, Show)

instance Listable a => Listable (Product a) where
  tiers = cons3 Product


data Sum a = Sum1 a | Sum2 a | Sum3 a
  deriving (Eq, Generic1, Ord, Show)

instance Listable a => Listable (Sum a) where
  tiers = cons1 Sum1 \/ cons1 Sum2 \/ cons1 Sum3


data Tree a = Leaf a | Branch [Tree a]
  deriving (Eq, Generic1, Ord, Show)

instance Listable a => Listable (Tree a) where
  tiers = cons1 Leaf \/ cons1 Branch

instance Eq1 Tree where liftEq = genericLiftEq
instance Ord1 Tree where liftCompare = genericLiftCompare
