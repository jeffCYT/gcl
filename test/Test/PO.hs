{-# LANGUAGE OverloadedStrings #-}

module Test.PO where

import Data.Text.Lazy hiding (map)
import Test.Tasty
import Test.Tasty.HUnit
import Prelude hiding (Ordering(..))

import Syntax.Predicate
import Syntax.Concrete hiding (LoopInvariant)
import qualified REPL as REPL
import GCL.WP2 (PO(..), POOrigin(..))
-- import GCL.WP2 (Obligation2(..), Specification2(..), ObliOrigin2(..))
import Data.Text.Prettyprint.Doc

import Syntax.Location
import Data.Loc
import Error
import Pretty ()

tests :: TestTree
tests = testGroup "Proof POs"
  [ statements
  , assertions
  , if'
  -- , loop
  ]

--------------------------------------------------------------------------------
-- | Expression

statements :: TestTree
statements = testGroup "simple statements"
  [ testCase "skip"
      $ run "{ True }     \n\
            \skip         \n\
            \{ 0 = 0 }    \n" @?= poList
      [ PO 0
          (assertion true)
          (assertion (0 === 0))
          (AroundSkip NoLoc)
      ]
  , testCase "abort"
      $ run "{ True }     \n\
            \abort        \n\
            \{ 0 = 0 }    \n" @?= poList
      [ PO 0
          (assertion true)
          (Constant false)
          (AroundSkip NoLoc)
      ]
  , testCase "assignment"
      $ run "{ True }     \n\
            \x := 1       \n\
            \{ 0 = x }    \n" @?= poList
      [ PO 0
          (assertion true)
          (assertion (number 0 `eqq` number 1))
          (AroundSkip NoLoc)
      ]
  , testCase "spec"
      $ run "{ True }     \n\
            \{!           \n\
            \!}           \n\
            \{ False }    \n" @?= poList
      [ PO 0
          (assertion true)
          (assertion false)
          (AroundSkip NoLoc)
      ]
  ]

assertions :: TestTree
assertions = testGroup "assertions"
  [ testCase "3 assertions"
      $ run "{ True }     \n\
            \{ False }    \n\
            \{ True }     \n" @?= poList
      [ PO 0
          (assertion true)
          (assertion false)
          (AroundSkip NoLoc)
      , PO 1
          (assertion false)
          (assertion true)
          (AroundSkip NoLoc)
      ]
  , testCase "2 assertions"
      $ run "{ 0 = 0 }    \n\
            \{ 0 = 1 }    \n" @?= poList
      [ PO 0
          (assertion (0 === 0))
          (assertion (0 === 1))
          (AroundSkip NoLoc)
      ]
  ]

if' :: TestTree
if' = testGroup "if statements"
  [ testCase "without precondition"
      $ run "{ 0 = 0 }              \n\
            \if 0 = 1 -> skip     \n\
            \ | 0 = 2 -> abort    \n\
            \fi                   \n\
            \{ 0 = 3 }            \n" @?= poList
        [ PO 0
          (assertion (0 === 0))
          (Disjunct [ guardIf (0 === 1), guardIf (0 === 2) ])
          (AroundSkip NoLoc)
        , PO 1
          (Conjunct [ assertion (0 === 0), guardIf (0 === 1) ])
          (assertion (0 === 3))
          (AroundSkip NoLoc)
        , PO 2
          (Conjunct [ assertion (0 === 0), guardIf (0 === 2) ])
          (Constant false)
          (AroundSkip NoLoc)
        ]
  , testCase "without precondition (nested)"
      $ run "{ 0 = 0 }              \n\
            \if 0 = 1 ->            \n\
            \     if 0 = 2 -> skip  \n\
            \     fi                \n\
            \fi                     \n\
            \{ 0 = 3 }\n" @?= poList
      [ PO 0
          (assertion (0 === 0))
          (guardIf (0 === 1))
          (AroundSkip NoLoc)
      , PO 1
          (Conjunct [ assertion (0 === 0), guardIf (0 === 1) ])
          (guardIf (0 === 2))
          (AroundSkip NoLoc)
      , PO 2
          (Conjunct [ assertion (0 === 0), guardIf (0 === 1), guardIf (0 === 2) ])
          (assertion (0 === 3))
          (AroundSkip NoLoc)

      ]
  , testCase "with precondition"
      $ run "{ 0 = 0 }            \n\
             \if 0 = 1 -> skip    \n\
             \ | 0 = 3 -> abort   \n\
             \fi                  \n\
             \{ 0 = 2 }           \n" @?= poList
      [ PO 0
          (assertion (0 === 0))
          (Disjunct [ guardIf (0 === 1), guardIf (0 === 3) ])
          (AroundSkip NoLoc)
      , PO 1
          (Conjunct [ assertion (0 === 0), guardIf (0 === 1) ])
          (assertion (0 === 2))
          (AroundSkip NoLoc)
      , PO 2
          (Conjunct [ assertion (0 === 0), guardIf (0 === 3) ])
          (Constant false)
          (AroundSkip NoLoc)
      ]
  ]

loop :: TestTree
loop = testGroup "loop statements"
  [ testCase "1 branch"
    $ run "{ 0 = 1 , bnd: A }     \n\
          \do 0 = 2 -> skip       \n\
          \od                     \n\
          \{ 0 = 0 }              \n" @?= poList
      [ PO 0
          (Conjunct [ loopInvariant (0 === 1)
                    , Negate (guardLoop (0 === 2))
                    ])
          (assertion (0 === 0))
          (LoopBase NoLoc)
      , PO 1
          (Conjunct [ loopInvariant (0 === 1)
                    , guardLoop (0 === 2)
                    ])
          (boundGTE (constant "A") (number 0))
          (LoopTermBase NoLoc)
      , PO 3
          (Conjunct [ loopInvariant (0 === 1)
                    , guardLoop (0 === 2)
                    , boundEq (constant "A") (variable "_bnd2")
                    ])
          (boundLT (constant "A") (variable "_bnd2"))
          (AroundSkip NoLoc)
      ]
  , testCase "2 branches"
    $ run "{ 0 = 1 , bnd: A }       \n\
          \do 0 = 2 -> skip         \n\
          \ | 0 = 3 -> abort od     \n\
          \{ 0 = 0 }\n" @?= poList
      [ PO 0
          (Conjunct [ loopInvariant (0 === 1)
                    , Negate (guardLoop (0 === 2))
                    , Negate (guardLoop (0 === 3))
                    ])
          (assertion (0 === 0))
          (LoopBase NoLoc)
      , PO 1
          (loopInvariant (0 === 1))
          (Constant false)
          (AroundAbort NoLoc)
      , PO 2
          (Conjunct [ loopInvariant (0 === 1)
                    , guardLoop (0 === 2)
                    , guardLoop (0 === 3)
                    ])
          (boundGTE (constant "A") (number 0))
          (LoopTermBase NoLoc)
      , PO 4
          (Conjunct [ loopInvariant (0 === 1)
                    , guardLoop (0 === 2)
                    , boundEq (constant "A") (variable "_bnd3")
                    ])
          (boundLT (constant "A") (variable "_bnd3"))
          (AroundSkip NoLoc)
      , PO 5
          (Conjunct [ loopInvariant (0 === 1)
                    , guardLoop (0 === 3)
                    , boundEq (constant "A") (variable "_bnd3")
                    ])
          (Constant false)
          (AroundAbort NoLoc)
      ]
  ]
-- loop :: TestTree
-- loop = testGroup "if statements"
--   [ testCase "loop" $ run "{ 0 = 1 , bnd: A }\ndo 0 = 2 -> skip od\n{ 0 = 0 }\n" @?= Right
--     [ PO 0
--         (Conjunct
--           [ koopInvariant (0 === 1)
--           , Negate (guardLoop (0 === 2))
--           ])
--         (assertion (0 === 0))
--         (LoopBase NoLoc)
--     , PO 1
--         (Conjunct
--           [ koopInvariant (0 === 1)
--           , guardLoop (0 === 2)
--           ])
--         (koopInvariant (0 === 1))
--         (AroundSkip NoLoc)
--     , PO 2
--         (Conjunct
--           [ koopInvariant (0 === 1)
--           , guardLoop (0 === 2)
--           ])
--         (Bound (constant "A" `gte` number 0))
--         (LoopTermBase NoLoc)
--     , PO 4
--         (Conjunct
--           [ Bound (constant "A" `lt` variable "_bnd3")
--           , koopInvariant (0 === 1)
--           , guardLoop (0 === 2)
--           , Bound (constant "A" `eqq` variable "_bnd3")
--           ])
--         (Bound (constant "A" `lt` variable "_bnd3"))
--         (AroundSkip NoLoc)
--     ]
--   ]


poList :: [PO] -> Either a POList
poList = Right . POList

run :: Text -> Either [Error] POList
run text = fmap (POList . map toNoLoc) $ REPL.scan "<test>" text
            >>= REPL.parseProgram "<test>"
            >>= REPL.sweep2

--------------------------------------------------------------------------------
-- | Wrap [Obligation] in POList for pretty-printing

newtype POList = POList [PO]
  deriving (Eq)

instance Show POList where
  show = show . pretty

instance Pretty POList where
  pretty (POList xs) = "POList" <> indent 1 (prettyList xs)
instance ToNoLoc POList where
  toNoLoc (POList xs) = POList (map toNoLoc xs)
