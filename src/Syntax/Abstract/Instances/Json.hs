module Syntax.Abstract.Instances.Json where

import Syntax.Abstract.Types
import Data.Aeson ( FromJSON, ToJSON )

instance ToJSON QTyCon

instance ToJSON Endpoint
instance ToJSON Interval
instance ToJSON TBase
instance ToJSON Type
instance ToJSON Expr
instance ToJSON Lit
instance ToJSON Bindings

instance FromJSON Expr
instance FromJSON Lit
instance FromJSON Bindings
