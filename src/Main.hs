{-# LANGUAGE
OverloadedStrings,
TemplateHaskell,
RecordWildCards,
RankNTypes,
NoImplicitPrelude
  #-}


module Main (main) where


-- General
import BasePrelude hiding (Category)
-- Lenses
import Lens.Micro.Platform
-- IO
import Control.Monad.IO.Class
-- Text
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Text.Format hiding (format)
import qualified Data.Text.Format as Format
import Data.Text.Format.Params (Params)
-- Web
import Lucid hiding (for_)
import Web.Spock
import Network.Wai.Middleware.Static


data Category = Category {
  _categoryId :: Int,
  _categoryTitle :: Text,
  _categoryItems :: [Text] }

makeLenses ''Category

data S = S {
  _nextId :: Int,
  _categories :: [Category] }

makeLenses ''S

categoryById :: Int -> Traversal' S Category
categoryById catId = categories . each . filtered ((== catId) . _categoryId)

main :: IO ()
main = runSpock 8080 $ spockT id $ do
  middleware (staticPolicy (addBase "static"))
  stateVar <- liftIO $ newIORef S {
    _nextId = 0,
    _categories = [] }
  get root $ do
    s <- liftIO $ readIORef stateVar
    lucid $ renderRoot s
  post "/add/category" $ do
    title <- param' "title"
    thisId <- liftIO $ view nextId <$> readIORef stateVar
    let newCategory = Category {
          _categoryId = thisId,
          _categoryTitle = title,
          _categoryItems = [] }
    liftIO $ modifyIORef stateVar $
      (categories %~ (++ [newCategory])) .
      (nextId %~ succ)
    lucid $ renderCategory newCategory
  post ("/add/item" <//> var) $ \catId -> do
    item <- param' "item"
    -- TODO: maybe do something if the category doesn't exist (e.g. has been
    -- already deleted)
    liftIO $ modifyIORef stateVar $
      categoryById catId . categoryItems %~ (++ [item])

renderRoot :: S -> Html ()
renderRoot s = do
  loadJS "https://ajax.googleapis.com/ajax/libs/jquery/2.2.0/jquery.min.js"
  loadJS "/js.js"
  div_ [id_ "categories"] $ do
    mapM_ renderCategory (s ^. categories)
  with button_ [onclick_ "addCategory('new category')"] "add category"

renderCategory :: Category -> Html ()
renderCategory Category{..} =
  div_ [id_ (format "cat{}" [_categoryId])] $ do
    h2_ (toHtml _categoryTitle)
    ul_ $ do
      mapM_ (li_ . toHtml) _categoryItems
    let buttonHandler = format "addItem({}, 'new item')" [_categoryId]
    with button_ [onclick_ buttonHandler] "add item"

-- Utils

loadJS :: Text -> Html ()
loadJS url = with (script_ "") [src_ url]

lucid :: Html a -> ActionT IO a
lucid = html . TL.toStrict . renderText

-- | Format a string (a bit 'Text.Printf.printf' but with different syntax).
format :: Params ps => Format -> ps -> Text
format f ps = TL.toStrict (Format.format f ps)
