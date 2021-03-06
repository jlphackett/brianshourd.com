{-# LANGUAGE OverloadedStrings #-}

{- Hakyll source code for brianshourd.com

Author: Brian Shourd
License: BSD

The vast majority of this was taken with minor (or no) alterations from
jaspervdj's website: <https://github.com/jaspervdj/jaspervdj>. However,
I did come up with (and I'm kind of proud of) the code for colorizing
the page based on a hash of the page, and the code for including the
Mathjax javascript based on a metadata flag. The latter could easily be
reused to insert arbitrary content based on a metadata flag.

See the functions `colorize` and `mathjax` for the implementations,  if you are interested. 
-}
module Main where

import Control.Applicative ((<$>))
import Data.Char (ord)
import Data.Map (lookup)
import Data.Monoid ((<>), mconcat, mempty)
import Text.Pandoc (WriterOptions (..), HTMLMathMethod (MathJax))

import Hakyll

main :: IO ()
main = hakyllWith config $ do
    -- Move images
    match "images/*" $ do
        route   idRoute
        compile copyFileCompiler

    -- Move static files
    match "static/**" $ do
        route $ gsubRoute "static/" (const "")
        compile copyFileCompiler

    -- Compress CSS
    match "css/style.scss" $ do
        route   $ setExtension ".css"
        compile $ getResourceString >>= sassify

    -- Buid Tags
    tags <- buildTags "posts/*" (fromCapture "tags/*.html")

    -- Render posts
    match "posts/*" $ do
        route   $ setExtension ".html"
        compile $ do
            pandocCompilerWith defaultHakyllReaderOptions pandocOptions
            >>= saveSnapshot "content" -- ^ For RSS
            >>= loadAndApplyTemplate "templates/post.html"
                    (postCtx tags <> defaultContext)
            >>= finish (titleCtx "Blog")

    -- Render posts page
    create ["posts.html"] $ do
        route idRoute
        compile $ postPage tags "All Posts" "posts/*"

     -- Create pages for tags
    tagsRules tags $ \tag pattern -> do
        let title = "Tag: " ++ tag
        route idRoute
        compile $ postPage tags title pattern

   -- Index
    create ["index.html"] $ do
        route idRoute
        compile $ do
            list <- postList tags "posts/*" $ fmap (take 5) . recentFirst
            makeItem ""
                >>= loadAndApplyTemplate "templates/index.html" 
                        (constField "posts" list <> defaultContext)
                >>= finish (titleCtx "Home")

    -- Pages
    match "pages/*.markdown" $ do
        route   $ composeRoutes (gsubRoute "pages/" (const "")) (setExtension ".html")
        compile $ pandocCompiler >>= finish mempty

    -- Rss Feed
    create ["rss.xml"] $ do
        route idRoute
        compile $ do
            posts <- fmap (take 10) . recentFirst 
                =<< loadAllSnapshots "posts/*" "content"
            renderRss feedConfiguration (bodyField "description" <>
                defaultContext) posts

    -- Read templates
    match "templates/*" $ compile templateCompiler

-- ==========================
-- Options and Configurations
-- ==========================
config :: Configuration
config = defaultConfiguration {
    deployCommand = "rsync -avcz _site/ briansho@brianshourd.com:public_html/"
}

feedConfiguration :: FeedConfiguration
feedConfiguration = FeedConfiguration
    { feedTitle       = "Blog - Brian Shourd"
    , feedDescription = "Thing I Learned Today"
    , feedAuthorName  = "Brian Shourd"
    , feedAuthorEmail = "brian.shourd@gmail.com"
    , feedRoot        = "http://brianshourd.com/"
    }

pandocOptions :: WriterOptions
pandocOptions = defaultHakyllWriterOptions
    { writerHTMLMathMethod = MathJax ""
    }

-- =================
-- Context functions
-- =================
postCtx :: Tags -> Context String
postCtx tags = mconcat
    [ dateField "date" "%B %e, %Y"
    , tagsField "tags" tags
    , defaultContext
    ]

topCtx :: Context String
topCtx = mconcat
    [ field "mathjax" mathjax
    , field "colorize" colorize
    ]

titleCtx :: String -> Context String
titleCtx title = constField "siteTitle" title

-- ===================
-- Auxiliary Functions
-- ===================
postList :: Tags -> Pattern -> ([Item String] -> Compiler [Item String]) -> Compiler String
postList tags pattern preprocess' = do
    postItemTpl <- loadBody "templates/postitem.html"
    posts'      <- loadAll pattern
    posts       <- preprocess' posts'
    applyTemplateList postItemTpl (postCtx tags) posts

-- Take in a string and perform a simple hash to get a valid hsl color
-- for sass
hashColor :: String -> String
hashColor s = "hsl(" ++ hash ++ ", 39, 60)" where
    hash = show . (flip mod) 360 . sum . map ord $ s

-- Run sass, then compress
sassify item = withItemBody (unixFilter "sass" ["-s", "--scss", "--trace", "--load-path", "css"]) item
    >>= return . fmap compressCss

-- Add css with custom colors based on a hash of the page contents
colorize :: Item String -> Compiler String
colorize item = do
    let color = hashColor . itemBody $ item
    cssItem <- makeItem "" 
        >>= loadAndApplyTemplate "templates/colorize.scss" (constField "color" color)
        >>= sassify
    return $ itemBody cssItem

-- Only load mathjax if there is actually math on the page, indicated in
-- the metadata option "math: true"
-- Originally found on John Lenz's blog:
-- http://blog.wuzzeb.org/posts/2012-06-08-hakyll-and-latex.html
-- and adapted to work with Hakyll 4
mathjax :: Item String -> Compiler String
mathjax item = do
    metadata <- getMetadata (itemIdentifier item)
    return $ case Data.Map.lookup "math" metadata of
        Just "true" -> "<script type=\"text/javascript\" src=\"http://cdn.mathjax.org/mathjax/latest/MathJax.js?config=TeX-AMS-MML_HTMLorMML\" />"
        otherwise   -> ""

getTitle :: Item String -> Compiler String
getTitle item = getMetadataField' (itemIdentifier item) "title"
    
-- Make a page from a list of posts. Was duplicated code, so refactored.
postPage :: Tags -> String -> Pattern -> Compiler (Item String)
postPage tags title pattern = do
    list <- postList tags pattern recentFirst
    makeItem ""
        >>= loadAndApplyTemplate "templates/posts.html"
                (constField "posts" list <> constField "title" title <>
                    defaultContext)
        >>= finish (titleCtx title)

-- Nearly everything loads the last template with the same options, only
-- a different title, then relativizes urls. Refactor it away.
finish :: Context String -> Item String -> Compiler (Item String)
finish context item = loadAndApplyTemplate 
        "templates/default.html" (context <> topCtx <> defaultContext) item
    >>= relativizeUrls
