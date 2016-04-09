{-# LANGUAGE
OverloadedStrings,
ScopedTypeVariables,
TypeFamilies,
DataKinds,
MultiWayIf,
FlexibleContexts,
NoImplicitPrelude
  #-}


module Main (main) where


-- General
import BasePrelude hiding (Category)
-- Monads and monad transformers
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Morph
-- Lenses
import Lens.Micro.Platform hiding ((&))
-- Containers
import qualified Data.Map as M
-- Text
import Data.Text (Text)
import qualified Data.Text          as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL
-- Paths
import System.FilePath ((</>))
-- Web
import Web.Spock hiding (head, get, text)
import qualified Web.Spock as Spock
import Web.Spock.Lucid
import Lucid
import Network.Wai.Middleware.Static (staticPolicy, addBase)
import qualified Network.HTTP.Types.Status as HTTP
import qualified Network.Wai as Wai
-- Feeds
import qualified Text.Feed.Types as Feed
import qualified Text.Feed.Util  as Feed
import qualified Text.Atom.Feed  as Atom
-- Highlighting
import Cheapskate.Highlight
-- Monitoring
import qualified System.Remote.Monitoring as EKG
import qualified Network.Wai.Metrics      as EKG
import qualified System.Metrics.Gauge     as EKG.Gauge
-- acid-state
import Data.Acid as Acid
-- Time
import Data.Time

-- Local
import Config
import Types
import View
import JS (JS(..), allJSFunctions)
import Utils
import Markdown


{- Note [acid-state]
~~~~~~~~~~~~~~~~~~~~

This application doesn't use a database – instead, it uses acid-state. Acid-state works as follows:

  * Everything is stored as Haskell values (in particular, all data is stored in 'GlobalState').

  * All changes to the state (and all queries) have to be done by using 'dbUpdate'/'dbQuery' and types (GetItem, SetItemName, etc) from the Types.hs module.

  * The data is kept in-memory, but all changes are logged to the disk (which lets us recover the state in case of a crash by reapplying the changes) and you can't access the state directly. When the application exits, it creates a snapshot of the state (called “checkpoint”) and writes it to the disk. Additionally, a checkpoint is created every hour (grep for “createCheckpoint”).

  * When any type is changed, we have to write a migration function that would read the old version of the type and turn it into the new version. It's enough to keep just one old version (and even that isn't needed after the migration happened and a new checkpoint has been created). For examples, look at “instance Migrate” in Types.hs. Also, all types involved in acid-state (whether migrate-able or not) have to have a SafeCopy instance, which is generated by 'deriveSafeCopy'.

  * There are actually ways to access the state directly (GetGlobalState and SetGlobalState), but the latter should only be used when doing something one-off (like migrating all IDs to a different ID scheme, or whatever).

-}

-- | A pointer to an open acid-state database (allows making queries/updates,
-- creating checkpoints, etc).
type DB = AcidState GlobalState

-- | Update something in the database.
dbUpdate :: (MonadIO m, HasSpock m, SpockState m ~ ServerState,
             EventState event ~ GlobalState, UpdateEvent event)
         => event -> m (EventResult event)
dbUpdate x = do
  db <- _db <$> Spock.getState
  liftIO $ Acid.update db x

-- | Read something from the database.
dbQuery :: (MonadIO m, HasSpock m, SpockState m ~ ServerState,
            EventState event ~ GlobalState, QueryEvent event)
        => event -> m (EventResult event)
dbQuery x = do
  db <- _db <$> Spock.getState
  liftIO $ Acid.query db x

------------------------------------------------------------------------------
-- Server state
------------------------------------------------------------------------------

data ServerState = ServerState {
  _config :: Config,
  _db     :: DB }

getConfig :: (Monad m, HasSpock m, SpockState m ~ ServerState)
          => m Config
getConfig = _config <$> Spock.getState

itemVar :: Path '[Uid Item]
itemVar = "item" <//> var

categoryVar :: Path '[Uid Category]
categoryVar = "category" <//> var

traitVar :: Path '[Uid Trait]
traitVar = "trait" <//> var

-- Call this whenever a user edits the database
addEdit :: (MonadIO m, HasSpock (ActionCtxT ctx m),
            SpockState (ActionCtxT ctx m) ~ ServerState)
        => Edit -> ActionCtxT ctx m ()
addEdit ed = do
  time <- liftIO $ getCurrentTime
  mbForwardedFor <- liftA2 (<|>) (Spock.header "Forwarded-For")
                                 (Spock.header "X-Forwarded-For")
  mbIP <- case mbForwardedFor of
    Nothing -> sockAddrToIP . Wai.remoteHost <$> Spock.request
    Just ff -> case readMaybe (T.unpack ip) of
      Nothing -> error ("couldn't read Forwarded-For address: " ++
                        show ip ++ " (full header: " ++
                        show ff ++ ")")
      Just i  -> return (Just i)
      where
        addr = T.strip . snd . T.breakOnEnd "," $ ff
        ip -- [IPv6]:port
           | T.take 1 addr == "[" =
               T.drop 1 (T.takeWhile (/= ']') addr)
           -- IPv4 or IPv4:port
           | T.any (== '.') addr =
               T.takeWhile (/= ':') addr
           -- IPv6 without port
           | otherwise =
               addr
  unless (isVacuousEdit ed) $
    dbUpdate (RegisterEdit ed mbIP time)

-- | Do an action that would undo an edit.
--
-- 'Left' signifies failure.
--
-- TODO: many of these don't work when the changed category/item/etc has been
-- deleted; this should change.
undoEdit :: (MonadIO m, HasSpock m, SpockState m ~ ServerState)
         => Edit -> m (Either String ())
undoEdit (Edit'AddCategory catId _) = do
  void <$> dbUpdate (DeleteCategory catId)
undoEdit (Edit'AddItem _catId itemId _) = do
  void <$> dbUpdate (DeleteItem itemId)
undoEdit (Edit'AddPro itemId traitId _) = do
  void <$> dbUpdate (DeleteTrait itemId traitId)
undoEdit (Edit'AddCon itemId traitId _) = do
  void <$> dbUpdate (DeleteTrait itemId traitId)
undoEdit (Edit'SetCategoryTitle catId old new) = do
  now <- view title <$> dbQuery (GetCategory catId)
  if now /= new
    then return (Left "title has been changed further")
    else Right () <$ dbUpdate (SetCategoryTitle catId old)
undoEdit (Edit'SetCategoryNotes catId old new) = do
  now <- markdownBlockText . view notes <$> dbQuery (GetCategory catId)
  if now /= new
    then return (Left "notes have been changed further")
    else Right () <$ dbUpdate (SetCategoryNotes catId old)
undoEdit (Edit'SetItemName itemId old new) = do
  now <- view name <$> dbQuery (GetItem itemId)
  if now /= new
    then return (Left "name has been changed further")
    else Right () <$ dbUpdate (SetItemName itemId old)
undoEdit (Edit'SetItemLink itemId old new) = do
  now <- view link <$> dbQuery (GetItem itemId)
  if now /= new
    then return (Left "link has been changed further")
    else Right () <$ dbUpdate (SetItemLink itemId old)
undoEdit (Edit'SetItemGroup itemId old new) = do
  now <- view group_ <$> dbQuery (GetItem itemId)
  if now /= new
    then return (Left "group has been changed further")
    else Right () <$ dbUpdate (SetItemGroup itemId old)
undoEdit (Edit'SetItemKind itemId old new) = do
  now <- view kind <$> dbQuery (GetItem itemId)
  if now /= new
    then return (Left "kind has been changed further")
    else Right () <$ dbUpdate (SetItemKind itemId old)
undoEdit (Edit'SetItemDescription itemId old new) = do
  now <- markdownBlockText . view description <$> dbQuery (GetItem itemId)
  if now /= new
    then return (Left "description has been changed further")
    else Right () <$ dbUpdate (SetItemDescription itemId old)
undoEdit (Edit'SetItemNotes itemId old new) = do
  now <- markdownBlockText . view notes <$> dbQuery (GetItem itemId)
  if now /= new
    then return (Left "notes have been changed further")
    else Right () <$ dbUpdate (SetItemNotes itemId old)
undoEdit (Edit'SetItemEcosystem itemId old new) = do
  now <- markdownBlockText . view ecosystem <$> dbQuery (GetItem itemId)
  if now /= new
    then return (Left "ecosystem has been changed further")
    else Right () <$ dbUpdate (SetItemEcosystem itemId old)
undoEdit (Edit'SetTraitContent itemId traitId old new) = do
  now <- markdownInlineText . view content <$> dbQuery (GetTrait itemId traitId)
  if now /= new
    then return (Left "trait has been changed further")
    else Right () <$ dbUpdate (SetTraitContent itemId traitId old)
undoEdit (Edit'DeleteCategory catId pos) = do
  dbUpdate (RestoreCategory catId pos)
undoEdit (Edit'DeleteItem itemId pos) = do
  dbUpdate (RestoreItem itemId pos)
undoEdit (Edit'DeleteTrait itemId traitId pos) = do
  dbUpdate (RestoreTrait itemId traitId pos)
undoEdit (Edit'MoveItem itemId direction) = do
  Right () <$ dbUpdate (MoveItem itemId (not direction))
undoEdit (Edit'MoveTrait itemId traitId direction) = do
  Right () <$ dbUpdate (MoveTrait itemId traitId (not direction))

renderMethods :: SpockM () () ServerState ()
renderMethods = Spock.subcomponent "render" $ do
  -- Title of a category
  Spock.get (categoryVar <//> "title") $ \catId -> do
    category <- dbQuery (GetCategory catId)
    lucidIO $ renderCategoryTitle category
  -- Notes for a category
  Spock.get (categoryVar <//> "notes") $ \catId -> do
    category <- dbQuery (GetCategory catId)
    lucidIO $ renderCategoryNotes category
  -- Item colors
  Spock.get (itemVar <//> "colors") $ \itemId -> do
    item <- dbQuery (GetItem itemId)
    category <- dbQuery (GetCategoryByItem itemId)
    let hue = getItemHue category item
    json $ M.fromList [("light" :: Text, hueToLightColor hue),
                       ("dark" :: Text, hueToDarkColor hue)]
  -- Item info
  Spock.get (itemVar <//> "info") $ \itemId -> do
    item <- dbQuery (GetItem itemId)
    category <- dbQuery (GetCategoryByItem itemId)
    lucidIO $ renderItemInfo category item
  -- Item description
  Spock.get (itemVar <//> "description") $ \itemId -> do
    item <- dbQuery (GetItem itemId)
    lucidIO $ renderItemDescription item
  -- Item ecosystem
  Spock.get (itemVar <//> "ecosystem") $ \itemId -> do
    item <- dbQuery (GetItem itemId)
    lucidIO $ renderItemEcosystem item
  -- Item notes
  Spock.get (itemVar <//> "notes") $ \itemId -> do
    item <- dbQuery (GetItem itemId)
    lucidIO $ renderItemNotes item

setMethods :: SpockM () () ServerState ()
setMethods = Spock.subcomponent "set" $ do
  -- Title of a category
  Spock.post (categoryVar <//> "title") $ \catId -> do
    content' <- param' "content"
    (edit, category) <- dbUpdate (SetCategoryTitle catId content')
    addEdit edit
    lucidIO $ renderCategoryTitle category
  -- Notes for a category
  Spock.post (categoryVar <//> "notes") $ \catId -> do
    content' <- param' "content"
    (edit, category) <- dbUpdate (SetCategoryNotes catId content')
    addEdit edit
    lucidIO $ renderCategoryNotes category
  -- Item info
  Spock.post (itemVar <//> "info") $ \itemId -> do
    -- TODO: [easy] add a cross-link saying where the form is handled in the
    -- code and other notes saying where stuff is rendered, etc
    name' <- T.strip <$> param' "name"
    link' <- T.strip <$> param' "link"
    kind' <- do
      kindName :: Text <- param' "kind"
      hackageName' <- (\x -> if T.null x then Nothing else Just x) <$>
                      param' "hackage-name"
      return $ case kindName of
        "library" -> Library hackageName'
        "tool"    -> Tool hackageName'
        _         -> Other
    group' <- do
      groupField <- param' "group"
      customGroupField <- param' "custom-group"
      if | groupField == "-"           -> return Nothing
         | groupField == newGroupValue -> return (Just customGroupField)
         | otherwise                   -> return (Just groupField)
    -- Modify the item
    -- TODO: actually validate the form and report errors
    unless (T.null name') $ do
      (edit, _) <- dbUpdate (SetItemName itemId name')
      addEdit edit
    case (T.null link', sanitiseUrl link') of
      (True, _) -> do
          (edit, _) <- dbUpdate (SetItemLink itemId Nothing)
          addEdit edit
      (_, Just l) -> do
          (edit, _) <- dbUpdate (SetItemLink itemId (Just l))
          addEdit edit
      _otherwise ->
          return ()
    do (edit, _) <- dbUpdate (SetItemKind itemId kind')
       addEdit edit
    -- This does all the work of assigning new colors, etc. automatically
    do (edit, _) <- dbUpdate (SetItemGroup itemId group')
       addEdit edit
    -- After all these edits we can render the item
    item <- dbQuery (GetItem itemId)
    category <- dbQuery (GetCategoryByItem itemId)
    lucidIO $ renderItemInfo category item
  -- Item description
  Spock.post (itemVar <//> "description") $ \itemId -> do
    content' <- param' "content"
    (edit, item) <- dbUpdate (SetItemDescription itemId content')
    addEdit edit
    lucidIO $ renderItemDescription item
  -- Item ecosystem
  Spock.post (itemVar <//> "ecosystem") $ \itemId -> do
    content' <- param' "content"
    (edit, item) <- dbUpdate (SetItemEcosystem itemId content')
    addEdit edit
    lucidIO $ renderItemEcosystem item
  -- Item notes
  Spock.post (itemVar <//> "notes") $ \itemId -> do
    content' <- param' "content"
    (edit, item) <- dbUpdate (SetItemNotes itemId content')
    addEdit edit
    lucidIO $ renderItemNotes item
  -- Trait
  Spock.post (itemVar <//> traitVar) $ \itemId traitId -> do
    content' <- param' "content"
    (edit, trait) <- dbUpdate (SetTraitContent itemId traitId content')
    addEdit edit
    lucidIO $ renderTrait itemId trait

addMethods :: SpockM () () ServerState ()
addMethods = Spock.subcomponent "add" $ do
  -- New category
  Spock.post "category" $ do
    title' <- param' "content"
    catId <- randomShortUid
    time <- liftIO getCurrentTime
    (edit, newCategory) <- dbUpdate (AddCategory catId title' time)
    addEdit edit
    lucidIO $ renderCategory newCategory
  -- New item in a category
  Spock.post (categoryVar <//> "item") $ \catId -> do
    name' <- param' "name"
    -- TODO: do something if the category doesn't exist (e.g. has been
    -- already deleted)
    itemId <- randomShortUid
    -- If the item name looks like a Hackage library, assume it's a Hackage
    -- library.
    time <- liftIO getCurrentTime
    (edit, newItem) <-
      if T.all (\c -> isAscii c && (isAlphaNum c || c == '-')) name'
        then dbUpdate (AddItem catId itemId name' time (Library (Just name')))
        else dbUpdate (AddItem catId itemId name' time Other)
    addEdit edit
    category <- dbQuery (GetCategory catId)
    lucidIO $ renderItem category newItem
  -- Pro (argument in favor of an item)
  Spock.post (itemVar <//> "pro") $ \itemId -> do
    content' <- param' "content"
    traitId <- randomLongUid
    (edit, newTrait) <- dbUpdate (AddPro itemId traitId content')
    addEdit edit
    lucidIO $ renderTrait itemId newTrait
  -- Con (argument against an item)
  Spock.post (itemVar <//> "con") $ \itemId -> do
    content' <- param' "content"
    traitId <- randomLongUid
    (edit, newTrait) <- dbUpdate (AddCon itemId traitId content')
    addEdit edit
    lucidIO $ renderTrait itemId newTrait

otherMethods :: SpockM () () ServerState ()
otherMethods = do
  -- Moving things
  Spock.subcomponent "move" $ do
    -- Move item
    Spock.post itemVar $ \itemId -> do
      direction :: Text <- param' "direction"
      edit <- dbUpdate (MoveItem itemId (direction == "up"))
      addEdit edit
    -- Move trait
    Spock.post (itemVar <//> traitVar) $ \itemId traitId -> do
      direction :: Text <- param' "direction"
      edit <- dbUpdate (MoveTrait itemId traitId (direction == "up"))
      addEdit edit

  -- Deleting things
  Spock.subcomponent "delete" $ do
    -- Delete category
    Spock.post categoryVar $ \catId -> do
      mbEdit <- dbUpdate (DeleteCategory catId)
      mapM_ addEdit mbEdit
    -- Delete item
    Spock.post itemVar $ \itemId -> do
      mbEdit <- dbUpdate (DeleteItem itemId)
      mapM_ addEdit mbEdit
    -- Delete trait
    Spock.post (itemVar <//> traitVar) $ \itemId traitId -> do
      mbEdit <- dbUpdate (DeleteTrait itemId traitId)
      mapM_ addEdit mbEdit

  -- Feeds
  -- TODO: this link shouldn't be absolute [absolute-links]
  baseUrl <- (</> "haskell") . T.unpack . _baseUrl <$> getConfig
  Spock.subcomponent "feed" $ do
    -- Feed for items in a category
    Spock.get categoryVar $ \catId -> do
      category <- dbQuery (GetCategory catId)
      let sortedItems = reverse $ sortBy cmp (category^.items)
            where cmp = comparing (^.created) <> comparing (^.uid)
      let route = "feed" <//> categoryVar
      let feedUrl = baseUrl </> T.unpack (renderRoute route (category^.uid))
          feedTitle = Atom.TextString (T.unpack (category^.title) ++
                                       " – Aelve Guide")
          feedLastUpdate = case sortedItems of
            (item:_) -> Feed.toFeedDateStringUTC Feed.AtomKind (item^.created)
            _        -> ""
      let feedBase = Atom.nullFeed feedUrl feedTitle feedLastUpdate
      atomFeed $ feedBase {
        Atom.feedEntries = map (itemToFeedEntry baseUrl category) sortedItems,
        Atom.feedLinks   = [Atom.nullLink feedUrl] }

itemToFeedEntry :: String -> Category -> Item -> Atom.Entry
itemToFeedEntry baseUrl category item =
  entryBase {
    Atom.entryLinks = [Atom.nullLink entryLink],
    Atom.entryContent = Just (Atom.HTMLContent (TL.unpack entryContent)) }
  where
    entryLink = baseUrl </>
                T.unpack (format "{}#item-{}"
                                 (categorySlug category, item^.uid))
    entryContent = Lucid.renderText (renderItemForFeed item)
    entryBase = Atom.nullEntry
      (T.unpack (uidToText (item^.uid)))
      (Atom.TextString (T.unpack (item^.name)))
      (Feed.toFeedDateStringUTC Feed.AtomKind (item^.created))

-- TODO: rename GlobalState to DB, and DB to AcidDB

lucidWithConfig
  :: (MonadIO m, HasSpock (ActionCtxT cxt m),
      SpockState (ActionCtxT cxt m) ~ ServerState)
  => HtmlT (ReaderT Config IO) a -> ActionCtxT cxt m a
lucidWithConfig x = do
  cfg <- getConfig
  lucidIO (hoist (flip runReaderT cfg) x)

main :: IO ()
main = do
  config <- readConfig
  let emptyState = GlobalState {
        _categories = [],
        _categoriesDeleted = [],
        _pendingEdits = [],
        _editIdCounter = 0 }
  do args <- getArgs
     when (args == ["--dry-run"]) $ do
       db :: DB <- openLocalStateFrom "state/" (error "couldn't load state")
       putStrLn "loaded the database successfully"
       closeAcidState db
       exitSuccess
  -- When we run in GHCi and we exit the main thread, the EKG thread (that
  -- runs the localhost:5050 server which provides statistics) may keep
  -- running. This makes running this in GHCi annoying, because you have to
  -- restart GHCi before every run. So, we kill the thread in the finaliser.
  ekgId <- newIORef Nothing
  -- See Note [acid-state] for the explanation of 'openLocalStateFrom',
  -- 'createCheckpoint', etc
  let prepare = openLocalStateFrom "state/" emptyState
      finalise db = do
        createCheckpoint db
        closeAcidState db
        mapM_ killThread =<< readIORef ekgId
  bracket prepare finalise $ \db -> do
    -- Create a checkpoint every hour. Note: if nothing was changed,
    -- acid-state overwrites the previous checkpoint, which saves us some
    -- space.
    forkOS $ forever $ do
      createCheckpoint db
      threadDelay (1000000 * 3600)
    -- EKG metrics
    ekg <- EKG.forkServer "localhost" 5050
    writeIORef ekgId (Just (EKG.serverThreadId ekg))
    waiMetrics <- EKG.registerWaiMetrics (EKG.serverMetricStore ekg)
    categoryGauge <- EKG.getGauge "db.categories" ekg
    itemGauge <- EKG.getGauge "db.items" ekg
    forkOS $ forever $ do
      globalState <- Acid.query db GetGlobalState
      let allCategories = globalState^.categories
      let allItems = allCategories^..each.items.each
      EKG.Gauge.set categoryGauge (fromIntegral (length allCategories))
      EKG.Gauge.set itemGauge (fromIntegral (length allItems))
      threadDelay (1000000 * 60)
    -- Run the server
    let serverState = ServerState {
          _config = config,
          _db     = db }
    let spockConfig = (defaultSpockCfg () PCNoDatabase serverState) {
          spc_maxRequestSize = Just (1024*1024) }
    runSpock 8080 $ spock spockConfig $ do
      middleware (EKG.metrics waiMetrics)
      middleware (staticPolicy (addBase "static"))
      -- Javascript
      Spock.get "/js.js" $ do
        setHeader "Content-Type" "application/javascript; charset=utf-8"
        Spock.bytes $ T.encodeUtf8 (fromJS allJSFunctions)
      -- CSS
      Spock.get "/highlight.css" $ do
        setHeader "Content-Type" "text/css; charset=utf-8"
        Spock.bytes $ T.encodeUtf8 (T.pack (styleToCss pygments))
      -- (css.css is a static file and so isn't handled here)

      -- Main page
      Spock.get root $
        lucidWithConfig $ renderRoot

      -- Admin page
      prehook adminHook $
        Spock.subcomponent "admin" $ do
          Spock.get root $ do
            edits <- view pendingEdits <$> dbQuery GetGlobalState
            s <- dbQuery GetGlobalState
            lucidIO $ renderAdmin s edits
          Spock.post ("edit" <//> var <//> "accept") $ \n -> do
            dbUpdate (RemovePendingEdit n)
            return ()
          Spock.post ("edit" <//> var <//> "undo") $ \n -> do
            (edit, _) <- dbQuery (GetEdit n)
            res <- undoEdit edit
            case res of
              Left err -> Spock.text (T.pack err)
              Right () -> do dbUpdate (RemovePendingEdit n)
                             Spock.text ""

      -- Donation page
      Spock.get "donate" $
        lucidWithConfig $ renderDonate

      -- Unwritten rules
      Spock.get "unwritten-rules" $ do
        lucidWithConfig $ renderUnwrittenRules

      -- Haskell
      Spock.subcomponent "haskell" $ do
        Spock.get root $ do
          s <- dbQuery GetGlobalState
          q <- param "q"
          lucidWithConfig $ renderHaskellRoot s q
        -- Category pages
        Spock.get var $ \path -> do
          -- The links look like /parsers-gao238b1 (because it's nice when
          -- you can find out where a link leads just by looking at it)
          let (_, catId) = T.breakOnEnd "-" path
          when (T.null catId) $
            Spock.jumpNext
          mbCategory <- dbQuery (GetCategoryMaybe (Uid catId))
          case mbCategory of
            Nothing -> Spock.jumpNext
            Just category -> do
              -- If the slug in the url is old (i.e. if it doesn't match the
              -- one we would've generated now), let's do a redirect
              when (categorySlug category /= path) $
                -- TODO: this link shouldn't be absolute [absolute-links]
                Spock.redirect ("/haskell/" <> categorySlug category)
              lucidWithConfig $ renderCategoryPage category
        -- The add/set methods return rendered parts of the structure (added
        -- categories, changed items, etc) so that the Javascript part could
        -- take them and inject into the page. We don't want to duplicate
        -- rendering on server side and on client side.
        renderMethods
        setMethods
        addMethods
        otherMethods

adminHook :: ActionCtxT ctx (WebStateM () () ServerState) ()
adminHook = do
  adminPassword <- _adminPassword <$> getConfig
  unless (adminPassword == "") $ do
    let check user pass =
          unless (user == "admin" && pass == adminPassword) $ do
            Spock.setStatus HTTP.status401
            Spock.text "Wrong password!"
    Spock.requireBasicAuth "Authenticate (login = admin)" check return

-- TODO: when a category with the same name exists, show an error message and
-- redirect to that other category

-- TODO: a function to find all links to Hackage that have version in them

-- TODO: why not compare Haskellers too? e.g. for April Fools' we could ask
-- people to list their pros and cons

-- TODO: is it indexable by Google? <given that we're hiding text and
-- Googlebot can execute Javascript>
