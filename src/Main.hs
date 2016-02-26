{-# LANGUAGE
OverloadedStrings,
TemplateHaskell,
RankNTypes,
FlexibleInstances,
FlexibleContexts,
QuasiQuotes,
ScopedTypeVariables,
FunctionalDependencies,
TypeFamilies,
DataKinds,
NoImplicitPrelude
  #-}


module Main (main) where


-- General
import BasePrelude hiding (Category)
-- Monads and monad transformers
import Control.Monad.State
-- Lenses
import Lens.Micro.Platform
-- Text
import Data.Text (Text)
import qualified Data.Text as T
import NeatInterpolation
-- Randomness
import System.Random
-- Web
import Lucid hiding (for_)
import Web.Spock hiding (get, text)
import qualified Web.Spock as Spock
import Network.Wai.Middleware.Static
import Web.PathPieces

-- Local
import JS (JS(..), ToJS, allJSFunctions)
import qualified JS
import Utils


-- | Unique id, used for many things – categories, items, and anchor ids.
-- Note that in HTML 5 using numeric ids for divs, spans, etc is okay.
type Uid = Int

randomUid :: MonadIO m => m Uid
randomUid = liftIO $ randomRIO (0, 10^(9::Int))

data Trait = Trait {
  _traitUid :: Uid,
  _traitContent :: Text }

makeFields ''Trait

data ItemKind
  = Library {_itemKindOnHackage :: Bool}
  | Other
  deriving (Eq, Show)

hackageLibrary :: ItemKind
hackageLibrary = Library True

makeFields ''ItemKind

data Item = Item {
  _itemUid  :: Uid,
  _itemName :: Text,
  _itemPros :: [Trait],
  _itemCons :: [Trait],
  _itemLink :: Maybe Url,
  _itemKind :: ItemKind }

makeFields ''Item

traitById :: Uid -> Lens' Item Trait
traitById uid' = singular $
  (pros.each . filtered ((== uid') . view uid)) `failing`
  (cons.each . filtered ((== uid') . view uid))

data Category = Category {
  _categoryUid :: Uid,
  _categoryTitle :: Text,
  _categoryNotes :: Text,
  _categoryItems :: [Item] }

makeFields ''Category

data GlobalState = GlobalState {
  _categories :: [Category] }

makeLenses ''GlobalState

categoryById :: Uid -> Lens' GlobalState Category
categoryById catId = singular $
  categories.each . filtered ((== catId) . view uid)

categoryByItem :: Uid -> Lens' GlobalState Category
categoryByItem itemId = singular $
  categories.each . filtered hasItem
  where
    hasItem category = itemId `elem` (category^..items.each.uid)

itemById :: Uid -> Lens' GlobalState Item
itemById itemId = singular $
  categories.each . items.each . filtered ((== itemId) . view uid)

emptyState :: GlobalState
emptyState = GlobalState {
  _categories = [] }

sampleState :: GlobalState
sampleState = do
  let lensItem = Item {
        _itemUid = 12,
        _itemName = "lens",
        _itemPros = [Trait 121 "The most widely used lenses library, by a \
                               \huge margin.",
                     Trait 123 "Contains pretty much everything you could \
                               \want – while other lens libraries mostly \
                               \only provide lenses for manipulating lists, \
                               \maps, tuples, and standard types like \
                               \`Maybe`/`Either`/etc, lens has functions \
                               \for manipulating filepaths, Template Haskell \
                               \structures, generics, complex numbers, \
                               \exceptions, and everything else in the \
                               \Haskell Platform.",
                     Trait 125 "Unlike most other libraries, has prisms – \
                               \a kind of lenses that can act both as \
                               \constructors and deconstructors at once. \
                               \They can be pretty useful when you're \
                               \dealing with exceptions, Template Haskell, \
                               \or JSON."],
        _itemCons = [Trait 122 "Takes a lot of time to compile, and has \
                               \a lot of dependencies as well.",
                     Trait 124 "Some of its advanced features are very \
                               \intimidating, and the whole library \
                               \may seem overengineered \
                               \(see [this post](http://fvisser.nl/post/2013/okt/11/why-i-dont-like-the-lens-library.html)).",
                     Trait 126 "Once you start using lenses for *everything* \
                               \(which is easier to do with lens than with \
                               \other libraries), your code may start \
                               \not looking like Haskell much \
                               \(see [this post](https://ro-che.info/articles/2014-04-24-lens-unidiomatic))."],
        _itemLink = Nothing,
        _itemKind = hackageLibrary }
  let microlensItem = Item {
        _itemUid = 13,
        _itemName = "microlens",
        _itemPros = [Trait 131 "Very small (the base package has no \
                               \dependencies at all, and features like \
                               \Template Haskell lens generation or \
                               \instances for `Vector`/`Text`/`HashMap` \
                               \are separated into other packages)."],
        _itemCons = [Trait 132 "Doesn't provide lens's more advanced \
                               \features (like prisms or indexed traversals).",
                     Trait 134 "Doesn't let you write code in fully “lensy” \
                               \style (since it omits lots of operators \
                               \and `*Of` functions from lens)."],
        _itemLink = Just "https://github.com/aelve/microlens",
        _itemKind = hackageLibrary }
  let lensesCategory = Category {
        _categoryUid = 1,
        _categoryTitle = "Lenses",
        _categoryNotes = "Lenses are first-class composable accessors.",
        _categoryItems = [lensItem, microlensItem] }

  let parsecItem = Item {
        _itemUid = 21,
        _itemName = "parsec",
        _itemPros = [Trait 211 "the most widely used package",
                     Trait 213 "has lots of tutorials, book coverage, etc"],
        _itemCons = [Trait 212 "development has stagnated"],
        _itemLink = Nothing,
        _itemKind = hackageLibrary }
  let megaparsecItem = Item {
        _itemUid = 22,
        _itemName = "megaparsec",
        _itemPros = [Trait 221 "the API is largely similar to Parsec, \
                               \so existing tutorials/code samples \
                               \could be reused and migration is easy"],
        _itemCons = [],
        _itemLink = Nothing,
        _itemKind = hackageLibrary }
  let attoparsecItem = Item {
        _itemUid = 23,
        _itemName = "attoparsec",
        _itemPros = [Trait 231 "very fast, good for parsing binary formats"],
        _itemCons = [Trait 232 "can't report positions of parsing errors",
                     Trait 234 "doesn't provide a monad transformer"],
        _itemLink = Nothing,
        _itemKind = hackageLibrary }
  let parsingCategory = Category {
        _categoryUid = 2,
        _categoryTitle = "Parsing",
        _categoryNotes = "Parsers are parsers.",
        _categoryItems = [parsecItem, megaparsecItem, attoparsecItem] }

  GlobalState {_categories = [lensesCategory, parsingCategory]}

itemVar :: Path '[Uid]
itemVar = "item" <//> var

categoryVar :: Path '[Uid]
categoryVar = "category" <//> var

traitVar :: Path '[Uid]
traitVar = "trait" <//> var

withGlobal :: (MonadIO m, HasSpock m, SpockState m ~ IORef GlobalState)
           => State GlobalState a -> m a
withGlobal act = do
  stateVar <- Spock.getState
  liftIO $ atomicModifyIORef' stateVar (swap . runState act)

renderMethods :: SpockM () () (IORef GlobalState) ()
renderMethods = Spock.subcomponent "render" $ do
  -- Help
  Spock.get "help" $ do
    visible <- param' "mode"
    lucid $ renderHelp visible
  -- Title of a category
  Spock.get (categoryVar <//> "title") $ \catId -> do
    category <- withGlobal $ use (categoryById catId)
    renderMode <- param' "mode"
    lucid $ renderCategoryTitle renderMode category
  -- Notes for a category
  Spock.get (categoryVar <//> "notes") $ \catId -> do
    category <- withGlobal $ use (categoryById catId)
    renderMode <- param' "mode"
    lucid $ renderCategoryNotes renderMode category
  -- Item info
  Spock.get (itemVar <//> "info") $ \itemId -> do
    item <- withGlobal $ use (itemById itemId)
    renderMode <- param' "mode"
    lucid $ renderItemInfo renderMode item
  -- All item traits
  Spock.get (itemVar <//> "traits") $ \itemId -> do
    item <- withGlobal $ use (itemById itemId)
    renderMode <- param' "mode"
    lucid $ renderItemTraits renderMode item
  -- A single trait
  Spock.get (itemVar <//> traitVar) $ \itemId traitId -> do
    trait <- withGlobal $ use (itemById itemId . traitById traitId)
    renderMode <- param' "mode"
    lucid $ renderTrait renderMode itemId trait

setMethods :: SpockM () () (IORef GlobalState) ()
setMethods = Spock.subcomponent "set" $ do
  -- Title of a category
  Spock.post (categoryVar <//> "title") $ \catId -> do
    content' <- param' "content"
    changedCategory <- withGlobal $ do
      categoryById catId . title .= content'
      use (categoryById catId)
    lucid $ renderCategoryTitle Editable changedCategory
  -- Notes for a category
  Spock.post (categoryVar <//> "notes") $ \catId -> do
    content' <- param' "content"
    changedCategory <- withGlobal $ do
      categoryById catId . notes .= content'
      use (categoryById catId)
    lucid $ renderCategoryNotes Editable changedCategory
  -- Item info
  Spock.post (itemVar <//> "info") $ \itemId -> do
    name' <- T.strip <$> param' "name"
    link' <- T.strip <$> param' "link"
    onHackage' <- (== Just ("on" :: Text)) <$> param "on-hackage"
    changedItem <- withGlobal $ do
      let item :: Lens' GlobalState Item
          item = itemById itemId
      -- TODO: actually validate the form and report errors
      unless (T.null name') $
        item.name .= name'
      case (T.null link', sanitiseUrl link') of
        (True, _)   -> item.link .= Nothing
        (_, Just l) -> item.link .= Just l
        _otherwise  -> return ()
      item.kind.onHackage .= onHackage'
      use item
    lucid $ renderItemInfo Editable changedItem
  -- Trait
  Spock.post (itemVar <//> traitVar) $ \itemId traitId -> do
    content' <- param' "content"
    changedTrait <- withGlobal $ do
      itemById itemId . traitById traitId . content .= content'
      use (itemById itemId . traitById traitId)
    lucid $ renderTrait Editable itemId changedTrait

addMethods :: SpockM () () (IORef GlobalState) ()
addMethods = Spock.subcomponent "add" $ do
  -- New category
  Spock.post "category" $ do
    content' <- param' "content"
    uid' <- randomUid
    let newCategory = Category {
          _categoryUid = uid',
          _categoryTitle = content',
          _categoryNotes = "(write some notes here, describe the category, etc)",
          _categoryItems = [] }
    withGlobal $ categories %= (newCategory :)
    lucid $ renderCategory newCategory
  -- New library in a category
  Spock.post (categoryVar <//> "library") $ \catId -> do
    name' <- param' "name"
    uid' <- randomUid
    let newItem = Item {
          _itemUid  = uid',
          _itemName = name',
          _itemPros = [],
          _itemCons = [],
          _itemLink = Nothing,
          _itemKind = hackageLibrary }
    -- TODO: maybe do something if the category doesn't exist (e.g. has been
    -- already deleted)
    withGlobal $ categoryById catId . items %= (++ [newItem])
    lucid $ renderItem Editable newItem
  -- Pro (argument in favor of a library)
  Spock.post (itemVar <//> "pro") $ \itemId -> do
    content' <- param' "content"
    uid' <- randomUid
    let newTrait = Trait uid' content'
    withGlobal $ itemById itemId . pros %= (++ [newTrait])
    lucid $ renderTrait Editable itemId newTrait
  -- Con (argument against a library)
  Spock.post (itemVar <//> "con") $ \itemId -> do
    content' <- param' "content"
    uid' <- randomUid
    let newTrait = Trait uid' content'
    withGlobal $ itemById itemId . cons %= (++ [newTrait])
    lucid $ renderTrait Editable itemId newTrait

otherMethods :: SpockM () () (IORef GlobalState) ()
otherMethods = do
  -- Search
  Spock.post "search" $ do
    query <- param' "query"
    let queryWords = T.words query
    let rank :: Category -> Int
        rank cat = sum [
          length (queryWords `intersect` (cat^..items.each.name)),
          length (queryWords `intersect` T.words (cat^.title)) ]
    cats <- withGlobal (use categories)
    let rankedCats
          | null queryWords = cats
          | otherwise       = filter ((/= 0) . rank) .
                              reverse . sortOn rank $ cats
    lucid $ renderCategoryList rankedCats

  -- Moving things
  Spock.subcomponent "move" $ do
    -- Move trait
    Spock.post (itemVar <//> traitVar) $ \itemId traitId -> do
      direction :: Text <- param' "direction"
      let move = if direction == "up" then moveUp else moveDown
      withGlobal $ do
        itemById itemId . pros %= move ((== traitId) . view uid)
        itemById itemId . cons %= move ((== traitId) . view uid)
    -- Move item
    Spock.post itemVar $ \itemId -> do
      direction :: Text <- param' "direction"
      let move = if direction == "up" then moveUp else moveDown
      withGlobal $ do
        categoryByItem itemId . items %= move ((== itemId) . view uid)

  -- Deleting things
  Spock.subcomponent "delete" $ do
    -- Delete trait
    Spock.post (itemVar <//> traitVar) $ \itemId traitId -> do
      withGlobal $ do
        itemById itemId . pros %= filter ((/= traitId) . view uid)
        itemById itemId . cons %= filter ((/= traitId) . view uid)
    -- Delete item
    Spock.post itemVar $ \itemId -> do
      withGlobal $ do
        categoryByItem itemId . items %= filter ((/= itemId) . view uid)

main :: IO ()
main = do
  stateVar <- newIORef sampleState
  let config = defaultSpockCfg () PCNoDatabase stateVar
  runSpock 8080 $ spock config $ do
    middleware (staticPolicy (addBase "static"))
    -- Main page
    Spock.get root $ do
      s <- liftIO $ readIORef stateVar
      lucid $ renderRoot s
    -- The add/set methods return rendered parts of the structure (added
    -- categories, changed items, etc) so that the Javascript part could take
    -- them and inject into the page. We don't want to duplicate rendering on
    -- server side and on client side.
    renderMethods
    setMethods
    addMethods
    otherMethods

renderRoot :: GlobalState -> HtmlT IO ()
renderRoot globalState = do
  includeJS "https://ajax.googleapis.com/ajax/libs/jquery/2.2.0/jquery.min.js"
  includeCSS "/css.css"
  -- Include definitions of all Javascript functions that we have defined in
  -- this file.
  script_ (fromJS allJSFunctions)
  h1_ "Collaborative notes on Haskell libraries and tools"
  -- By default help is rendered hidden, and then showOrHideHelp reads a
  -- value from local storage and decides whether to show help or not. On one
  -- hand, it means that people with Javascript turned off won't be able to
  -- see help; on another hand, those people don't need help anyway because
  -- they won't be able to edit anything either.
  renderHelp Hidden
  onPageLoad $ JS.showOrHideHelp ("#help" :: JQuerySelector, helpVersion)
  -- TODO: use ordinary form-post search instead of Javascript search (for
  -- people with NoScript)
  textInput [id_ "search", placeholder_ "search"] $
    JS.search ("#categories" :: JQuerySelector, inputValue)
  textInput [placeholder_ "add a category"] $
    JS.addCategory ("#categories" :: JQuerySelector, inputValue) <> clearInput
  -- TODO: sort categories by popularity, somehow? or provide a list of
  -- “commonly used categories” or even a nested catalog
  renderCategoryList (globalState^.categories)
  -- TODO: perhaps use infinite scrolling/loading?
  -- TODO: add links to source and donation buttons
  -- TODO: add Piwik/Google Analytics
  -- TODO: maybe add a button like “give me random category that is unfinished”
  -- TODO: add CSS for blocks of code

-- Don't forget to change helpVersion when the text changes substantially
-- and you think the users should reread it.
helpVersion :: Int
helpVersion = 1

renderHelp :: Visible -> HtmlT IO ()
renderHelp Hidden =
  div_ [id_ "help"] $
    textButton "show help" $
      JS.showHelp ("#help" :: JQuerySelector, helpVersion)
renderHelp Shown =
  div_ [id_ "help"] $ do
    textButton "hide help" $
      JS.hideHelp ("#help" :: JQuerySelector, helpVersion)
    renderMarkdownBlock [text|
      You can edit everything, without registration. (But if you delete
      everything, I'll roll it back and then make a voodoo doll of you
      and stick some needles into it).
  
      The most important rule is: **it's collaborative notes, not Wikipedia**.
      In other words, incomplete entries like this are welcome here:
  
      > **pros:** pretty nice API\
      > **cons:** buggy (see an example on my Github, here's the link)
  
      Some additional guidelines/observations/etc that probably make sense:
  
        * sort pros/cons by importance
  
        * if you don't like something for any reason, edit it
  
        * if you're unsure about something, still write it
          (just warn others that you're unsure)
  
        * if you have useful information of any kind that doesn't fit,
          add it to the category notes
      |]

renderCategoryList :: [Category] -> HtmlT IO ()
renderCategoryList cats =
  div_ [id_ "categories"] $
    mapM_ renderCategory cats

renderCategoryTitle :: Editable -> Category -> HtmlT IO ()
renderCategoryTitle editable category =
  h2_ $ do
    a_ [class_ "anchor", href_ ("#" <> tshow (category^.uid))] "#"
    titleNode <- thisNode
    case editable of
      Editable -> do
        toHtml (category^.title)
        emptySpan "1em"
        textButton "edit" $
          JS.setCategoryTitleMode (titleNode, category^.uid, InEdit)
      InEdit -> do
        textInput [value_ (category^.title)] $
          JS.submitCategoryTitle (titleNode, category^.uid, inputValue) <>
          clearInput
        emptySpan "1em"
        textButton "cancel" $
          JS.setCategoryTitleMode (titleNode, category^.uid, Editable)

renderCategoryNotes :: Editable -> Category -> HtmlT IO ()
renderCategoryNotes editable category =
  div_ $ do
    this <- thisNode
    case editable of
      Editable -> do
        -- TODO: use shortcut-links
        renderMarkdownBlock (category^.notes)
        textButton "edit description" $
          JS.setCategoryNotesMode (this, category^.uid, InEdit)
      InEdit -> do
        textareaId <- randomUid
        textarea_ [id_ (tshow textareaId),
                   rows_ "10", style_ "width:100%;resize:vertical"] $
          toHtml (category^.notes)
        button "Save" [] $ do
          -- «$("#<textareaId>").val()» is a Javascript expression that
          -- returns text contained in the textarea
          let textareaValue = JS $ format "$(\"#{}\").val()" [textareaId]
          JS.submitCategoryNotes (this, category^.uid, textareaValue)
        emptySpan "6px"
        button "Cancel" [] $
          JS.setCategoryNotesMode (this, category^.uid, Editable)
        emptySpan "6px"
        "Markdown"

renderCategory :: Category -> HtmlT IO ()
renderCategory category =
  div_ [class_ "category", id_ (tshow (category^.uid))] $ do
    renderCategoryTitle Editable category
    renderCategoryNotes Editable category
    itemsNode <- div_ [class_ "items"] $ do
      mapM_ (renderItem Normal) (category^.items)
      thisNode
    textInput [placeholder_ "add an item"] $
      JS.addLibrary (itemsNode, category^.uid, inputValue) <> clearInput

-- TODO: add arrows for moving items up and down in category, and something
-- to delete an item – those things could be at the left side, like on Reddit

-- TODO: allow colors for grouping (e.g. van Laarhoven lens libraries go one
-- way, other libraries go another way) (and provide a legend under the
-- category) (and sort by colors)

-- TODO: perhaps use jQuery Touch Punch or something to allow dragging items
-- instead of using arrows? Touch Punch works on mobile, too
renderItem :: Editable -> Item -> HtmlT IO ()
renderItem editable item =
  div_ [class_ "item"] $ do
    itemNode <- thisNode
    -- TODO: the controls and item-info should be aligned (currently the
    -- controls are smaller)
    -- TODO: the controls should be “outside” of the main body width
    -- TODO: styles for all this should be in css.css
    div_ [class_ "item-controls"] $ do
      imgButton "/arrow-thick-top.svg" [width_ "12px",
                                        style_ "margin-bottom:5px"] $
        -- TODO: the item should blink or somehow else show where it has been
        -- moved
        JS.moveItemUp (item^.uid, itemNode)
      imgButton "/arrow-thick-bottom.svg" [width_ "12px",
                                           style_ "margin-bottom:5px"] $
        JS.moveItemDown (item^.uid, itemNode)
      imgButton "/x.svg" [width_ "12px"] $
        JS.deleteItem (item^.uid, itemNode, item^.name)
    -- This div is needed for “display:flex” on the outer div to work (which
    -- makes item-controls be placed to the left of everything else)
    div_ [style_ "width:100%"] $ do
      renderItemInfo Editable item
      case editable of
        Normal -> do
          renderItemTraits Normal item
        Editable -> do
          renderItemTraits Editable item

-- TODO: warn when a library isn't on Hackage but is supposed to be
-- TODO: give a link to oldest available docs when the new docs aren't there
renderItemInfo :: Editable -> Item -> HtmlT IO ()
renderItemInfo editable item =
  div_ [class_ "item-info"] $ do
    this <- thisNode
    case editable of
      Editable -> span_ [style_ "font-size:150%"] $ do
        -- If the library is on Hackage, the title links to its Hackage page;
        -- otherwise, it doesn't link anywhere. Even if the link field is
        -- present, it's going to be rendered as “(site)”, not linked in the
        -- title.
        let hackageLink = "https://hackage.haskell.org/package/" <> item^.name
        case item^?kind.onHackage of
          Just True  -> a_ [href_ hackageLink] (toHtml (item^.name))
          _otherwise -> toHtml (item^.name)
        case item^.link of
          Just l  -> " (" >> a_ [href_ l] "site" >> ")"
          Nothing -> return ()
        emptySpan "1em"
        textButton "edit details" $
          JS.setItemInfoMode (this, item^.uid, InEdit)
        -- TODO: link to Stackage too
        -- TODO: should check for Stackage automatically
      InEdit -> do
        let handler s = JS.submitItemInfo (this, item^.uid, s)
        form_ [onFormSubmit handler] $ do
          label_ $ do
            "Package name: "
            br_ []
            input_ [type_ "text", name_ "name",
                    value_ (item^.name)]
          br_ []
          label_ $ do
            "Link to Hackage: "
            input_ $ [type_ "checkbox", name_ "on-hackage"] ++
                     [checked_ | item^?kind.onHackage == Just True]
          br_ []
          label_ $ do
            "Site (optional): "
            br_ []
            input_ [type_ "text", name_ "link",
                    value_ (fromMaybe "" (item^.link))]
          br_ []
          input_ [type_ "submit", value_ "Save"]
          button "Cancel" [] $
            JS.setItemInfoMode (this, item^.uid, Editable)

-- TODO: categories that don't directly compare libraries but just list all
-- libraries about something (e.g. Yesod plugins, or whatever)

renderItemTraits :: Editable -> Item -> HtmlT IO ()
renderItemTraits editable item =
  div_ [class_ "item-traits"] $ do
    this <- thisNode
    div_ [class_ "traits-groups-container"] $ do
      div_ [class_ "traits-group"] $ do
        p_ "Pros:"
        case editable of
          Normal ->
            ul_ $ mapM_ (renderTrait Normal (item^.uid)) (item^.pros)
          Editable -> do
            listNode <- ul_ $ do
              mapM_ (renderTrait Editable (item^.uid)) (item^.pros)
              thisNode
            textInput [placeholder_ "add pro"] $
              JS.addPro (listNode, item^.uid, inputValue) <> clearInput
      -- TODO: maybe add a separator explicitly? instead of CSS
      div_ [class_ "traits-group"] $ do
        p_ "Cons:"
        -- TODO: maybe add a line here?
        case editable of
          Normal ->
            ul_ $ mapM_ (renderTrait Normal (item^.uid)) (item^.cons)
          Editable -> do
            listNode <- ul_ $ do
              mapM_ (renderTrait Editable (item^.uid)) (item^.cons)
              thisNode
            textInput [placeholder_ "add con"] $
              JS.addCon (listNode, item^.uid, inputValue) <> clearInput
    case editable of
      Normal -> textButton "edit pros/cons" $
        JS.setItemTraitsMode (this, item^.uid, Editable)
      Editable -> textButton "edit off" $
        JS.setItemTraitsMode (this, item^.uid, Normal)

renderTrait :: Editable -> Uid -> Trait -> HtmlT IO ()
-- TODO: probably use renderMarkdownBlock here as well
renderTrait Normal _itemId trait = li_ (renderMarkdownLine (trait^.content))
renderTrait Editable itemId trait = li_ $ do
  this <- thisNode
  renderMarkdownLine (trait^.content)
  imgButton "/arrow-thick-top.svg" [width_ "12px"] $
    JS.moveTraitUp (itemId, trait^.uid, this)
  imgButton "/arrow-thick-bottom.svg" [width_ "12px"] $
    JS.moveTraitDown (itemId, trait^.uid, this)
  -- TODO: these 3 icons in a row don't look nice
  -- TODO: there should be some way to undelete things (e.g. a list of
  -- deleted traits under each item)
  imgButton "/x.svg" [width_ "12px"] $
    JS.deleteTrait (itemId, trait^.uid, this, trait^.content)
  textButton "edit" $
    JS.setTraitMode (this, itemId, trait^.uid, InEdit)
-- TODO: and textarea here
renderTrait InEdit itemId trait = li_ $ do
  this <- thisNode
  textInput [value_ (trait^.content)] $
    JS.submitTrait (this, itemId, trait^.uid, inputValue) <> clearInput
  textButton "cancel" $
    JS.setTraitMode (this, itemId, trait^.uid, Editable)

-- Utils

onPageLoad :: JS -> HtmlT IO ()
onPageLoad js = script_ $ format "$(document).ready(function(){{}});" [js]

emptySpan :: Text -> HtmlT IO ()
emptySpan w = span_ [style_ ("margin-left:" <> w)] mempty

textInput :: [Attribute] -> JS -> HtmlT IO ()
textInput attrs handler =
  input_ (type_ "text" : onkeyup_ handler' : attrs)
  where
    handler' = format "if (event.keyCode == 13) {{}}" [handler]

inputValue :: JS
inputValue = JS "this.value"

clearInput :: JS
clearInput = JS "this.value = '';"

onFormSubmit :: (JS -> JS) -> Attribute
onFormSubmit f = onsubmit_ $ format "{} return false;" [f (JS "this")]

button :: Text -> [Attribute] -> JS -> HtmlT IO ()
button value attrs handler =
  input_ (type_ "button" : value_ value : onclick_ handler' : attrs)
  where
    handler' = fromJS handler

-- A text button looks like “[cancel]”
-- 
-- TODO: consider dotted links instead?
-- TODO: text button links shouldn't be marked as visited
textButton
  :: Text         -- ^ Button text
  -> JS           -- ^ Onclick handler
  -> HtmlT IO ()
textButton caption (JS handler) =
  span_ [class_ "text-button"] $
    a_ [href_ "javascript:void(0)", onclick_ handler] (toHtml caption)

-- So far all icons used here have been from <https://useiconic.com/open/>
imgButton :: Url -> [Attribute] -> JS -> HtmlT IO ()
imgButton src attrs (JS handler) =
  a_ [href_ "javascript:void(0)", onclick_ handler] (img_ (src_ src : attrs))

type JQuerySelector = Text

thisNode :: HtmlT IO JQuerySelector
thisNode = do
  uid' <- randomUid
  -- If the class name ever changes, fix 'JS.moveNodeUp' and
  -- 'JS.moveNodeDown'.
  span_ [id_ (tshow uid'), class_ "dummy"] mempty
  return (format ":has(> #{})" [uid'])

data Editable = Normal | Editable | InEdit

instance PathPiece Editable where
  fromPathPiece "normal"   = Just Normal
  fromPathPiece "editable" = Just Editable
  fromPathPiece "in-edit"  = Just InEdit
  fromPathPiece _          = Nothing
  toPathPiece Normal   = "normal"
  toPathPiece Editable = "editable"
  toPathPiece InEdit   = "in-edit"

instance ToJS Editable where
  toJS = JS . tshow . toPathPiece

data Visible = Hidden | Shown

instance PathPiece Visible where
  fromPathPiece "hidden" = Just Hidden
  fromPathPiece "shown"  = Just Shown
  fromPathPiece _        = Nothing
  toPathPiece Hidden = "hidden"
  toPathPiece Shown  = "shown"

instance ToJS Visible where
  toJS = JS . tshow . toPathPiece

-- TODO: why not compare Haskellers too?
