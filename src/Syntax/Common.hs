{-# LANGUAGE OverloadedStrings #-}

module Syntax.Common where

import Data.Aeson
import Data.Loc
import Data.Aeson.Types (Parser)

--------------------------------------------------------------------------------
-- | Make Loc/Pos instances of FromJSON and ToJSON

instance ToJSON Pos where
  toJSON (Pos filepath line column offset) = toJSON (filepath, line, column, offset)

instance FromJSON Pos where
  parseJSON v = do 
      (filepath, line, column, offset) <- parseJSON v
      return $ Pos filepath line column offset

instance ToJSON Loc where
  toJSON NoLoc = 
    object
      [ "tag" .= String "NoLoc"
      ]
  toJSON (Loc start end) =
    object
      [ "tag" .= String "Loc"
      , "contents" .= (start, end)
      ]

instance FromJSON Loc where
   parseJSON = withObject "Loc" $ \v -> do 
    result <- v .:? "tag" :: Parser (Maybe String)
    case result of 
     Just "Loc" -> Loc <$> v .: "start" <*> v .: "end" 
     _ -> return NoLoc 