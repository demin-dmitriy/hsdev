{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}

module HsDev.Symbols.Location (
	ModulePackage(..), ModuleLocation(..), moduleStandalone,
	Position(..), Region(..), region, regionLines, regionStr,
	Location(..),

	packageName, packageVersion,
	moduleFile, moduleProject, moduleCabal, modulePackage, cabalModuleName, moduleSourceName,
	positionLine, positionColumn,
	regionFrom, regionTo,
	locationModule, locationPosition,

	packageOpt,
	recalcTabs,

	module HsDev.Cabal
	) where

import Control.Applicative
import Control.DeepSeq (NFData(..))
import Control.Lens (makeLenses, preview, view)
import Control.Monad (join)
import Data.Aeson
import Data.Char (isSpace, isDigit)
import Data.List (intercalate, findIndex)
import Data.Maybe
import Text.Read (readMaybe)

import HsDev.Cabal
import HsDev.Project
import HsDev.Util ((.::))

data ModulePackage = ModulePackage {
	_packageName :: String,
	_packageVersion :: String }
		deriving (Eq, Ord)

makeLenses ''ModulePackage

instance NFData ModulePackage where
	rnf (ModulePackage n v) = rnf n `seq` rnf v

instance Show ModulePackage where
	show (ModulePackage n "") = n
	show (ModulePackage n v) = n ++ "-" ++ v

instance Read ModulePackage where
	readsPrec _ str = case pkg of
		"" -> []
		_ -> [(ModulePackage n v, str')]
		where
			(pkg, str') = break isSpace str
			(rv, rn) = span versionChar $ reverse pkg
			v = reverse rv
			n = reverse $ dropWhile (== '-') rn

			versionChar ch = isDigit ch || ch == '.'

instance ToJSON ModulePackage where
	toJSON (ModulePackage n v) = object [
		"name" .= n,
		"version" .= v]

instance FromJSON ModulePackage where
	parseJSON = withObject "module package" $ \v ->
		ModulePackage <$> (v .:: "name") <*> (v .:: "version")

-- | Location of module
data ModuleLocation =
	FileModule { _moduleFile :: FilePath, _moduleProject :: Maybe Project } |
	CabalModule { _moduleCabal :: Cabal, _modulePackage :: Maybe ModulePackage, _cabalModuleName :: String } |
	ModuleSource { _moduleSourceName :: Maybe String }
		deriving (Eq, Ord)

makeLenses ''ModuleLocation

moduleStandalone :: ModuleLocation -> Bool
moduleStandalone = (== Just Nothing) . preview moduleProject

instance NFData ModuleLocation where
	rnf (FileModule f p) = rnf f `seq` rnf p
	rnf (CabalModule c p n) = rnf c `seq` rnf p `seq` rnf n
	rnf (ModuleSource m) = rnf m

instance Show ModuleLocation where
	show (FileModule f p) = f ++ maybe "" (" in " ++) (fmap (view projectPath) p)
	show (CabalModule _ p n) = n ++ maybe "" (" in package " ++) (fmap show p)
	show (ModuleSource m) = fromMaybe "" m

instance ToJSON ModuleLocation where
	toJSON (FileModule f p) = object ["file" .= f, "project" .= fmap (view projectCabal) p]
	toJSON (CabalModule c p n) = object ["cabal" .= c, "package" .= fmap show p, "name" .= n]
	toJSON (ModuleSource s) = object ["source" .= s]

instance FromJSON ModuleLocation where
	parseJSON = withObject "module location" $ \v ->
		(FileModule <$> v .:: "file" <*> (fmap project <$> (v .:: "project"))) <|>
		(CabalModule <$> v .:: "cabal" <*> fmap (join . fmap readMaybe) (v .:: "package") <*> v .:: "name") <|>
		(ModuleSource <$> v .:: "source")

data Position = Position {
	_positionLine :: Int,
	_positionColumn :: Int }
		deriving (Eq, Ord, Read)

makeLenses ''Position

instance NFData Position where
	rnf (Position l c) = rnf l `seq` rnf c

instance Show Position where
 	show (Position l c) = show l ++ ":" ++ show c

instance ToJSON Position where
	toJSON (Position l c) = object [
		"line" .= l,
		"column" .= c]

instance FromJSON Position where
	parseJSON = withObject "position" $ \v -> Position <$>
		v .:: "line" <*>
		v .:: "column"

data Region = Region {
	_regionFrom :: Position,
	_regionTo :: Position }
		deriving (Eq, Ord, Read)

makeLenses ''Region

region :: Position -> Position -> Region
region f t = Region (min f t) (max f t)

regionLines :: Region -> Int
regionLines (Region f t) = succ (view positionLine t - view positionLine f)

-- | Get string at region
regionStr :: Region -> String -> String
regionStr r@(Region f t) s = intercalate "\n" $ drop (pred $ view positionColumn f) fline' : tl where
	s' = take (regionLines r) $ drop (pred (view positionLine f)) $ lines s
	(fline:tl) = init s' ++ [take (pred $ view positionColumn t) (last s')]
	fline' = concatMap untab fline where
		untab :: Char -> String
		untab '\t' = replicate 8 ' '
		untab ch = [ch]

instance NFData Region where
	rnf (Region f t) = rnf f `seq` rnf t

instance Show Region where
	show (Region f t) = show f ++ "-" ++ show t

instance ToJSON Region where
	toJSON (Region f t) = object [
		"from" .= f,
		"to" .= t]

instance FromJSON Region where
	parseJSON = withObject "region" $ \v -> Region <$>
		v .:: "from" <*>
		v .:: "to"

-- | Location of symbol
data Location = Location {
	_locationModule :: ModuleLocation,
	_locationPosition :: Maybe Position }
		deriving (Eq, Ord)

makeLenses ''Location

instance NFData Location where
	rnf (Location m p) = rnf m `seq` rnf p

instance Show Location where
	show (Location m p) = show m ++ ":" ++ show p

instance ToJSON Location where
	toJSON (Location ml p) = object [
		"module" .= ml,
		"pos" .= p]

instance FromJSON Location where
	parseJSON = withObject "location" $ \v -> Location <$>
		v .:: "module" <*>
		v .:: "pos"

packageOpt :: Maybe ModulePackage -> [String]
packageOpt = maybeToList . fmap (("-package " ++) . view packageName)

-- | Recalc position to interpret '\t' as one symbol instead of 8
recalcTabs :: String -> Position -> Position
recalcTabs cts (Position l c) = Position l c' where
	line = listToMaybe $ drop (pred l) $ lines cts
	c' = case line of
		Nothing -> c
		Just line' -> let sizes = map charSize line' in
			succ . fromMaybe (length sizes) .
			findIndex (>= pred c) .
			scanl (+) 0 $ sizes
	charSize :: Char -> Int
	charSize '\t' = 8
	charSize _ = 1
