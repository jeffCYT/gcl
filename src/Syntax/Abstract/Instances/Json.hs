module Syntax.Abstract.Instances.Json where

import Syntax.Abstract.Types
import Data.Aeson ( FromJSON, ToJSON )

instance ToJSON Endpoint
instance ToJSON Interval
instance ToJSON TBase
instance ToJSON Type
instance ToJSON Expr
instance ToJSON ElimCase 
instance ToJSON Pattern 
instance ToJSON Lit

instance FromJSON Expr
instance FromJSON ElimCase 
instance FromJSON Pattern 
instance FromJSON Lit
