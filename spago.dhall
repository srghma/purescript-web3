{ name = "web3"
, dependencies =
  [ "aff"
  , "coroutines"
  , "coroutine-transducers"
  , "effect"
  , "errors"
  , "eth-core"
  , "foreign"
  , "foreign-generic"
  , "fork"
  , "heterogeneous"
  , "parsing"
  , "partial"
  , "profunctor-lenses"
  , "psci-support"
  , "tagged"
  , "transformers"
  , "typelevel-prelude"
  , "variant"
  , "argonaut"
  , "arrays"
  , "bifunctors"
  , "bytestrings"
  , "control"
  , "either"
  , "exceptions"
  , "foldable-traversable"
  , "foreign-object"
  , "integers"
  , "maybe"
  , "newtype"
  , "parallel"
  , "prelude"
  , "record"
  , "ring-modules"
  , "simple-json"
  , "strings"
  , "tailrec"
  , "tuples"
  , "unfoldable"
  , "debug"
  ]
, packages = ./packages.dhall
, sources = [ "src/**/*.purs" ]
}
