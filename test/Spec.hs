{-# LANGUAGE OverloadedStrings #-}

import Duffer
import Test.Hspec
import System.Process
import Data.ByteString (hGetContents)
import Data.ByteString.UTF8 (toString)

main :: IO ()
main = do

    blobs   <- objectsOfType "blob"
    trees   <- objectsOfType "tree"
    commits <- objectsOfType "commit"
    tags    <- objectsOfType "tag"

    let readCurrent = readHashObject ".git"

    hspec . parallel $ do
        describe "blob" $
            it "correctly parses and hashes all blobs" $
                mapM_ readCurrent blobs
        describe "tree" $
            it "correctly parses and hashes all trees" $
                mapM_ readCurrent trees
        describe "commit" $
            it "correctly parses and hashes all commits" $
                mapM_ readCurrent commits
        describe "tag" $
            it "correctly parses and hashes all tags" $
                mapM_ readCurrent tags

objectsOfType :: String -> IO [String]
objectsOfType objectType = do
    (_, Just h1, _, _) <- createProcess (shell "git rev-list --objects --all") {std_out = CreatePipe}
    (_, Just h2, _, _) <- createProcess (shell "git cat-file --batch-check='%(objectname) %(objecttype) %(rest)'") {std_out = CreatePipe, std_in = UseHandle h1}
    (_, Just h3, _, _) <- createProcess (shell $ "grep '^[^ ]* " ++ objectType ++ "'") {std_out = CreatePipe, std_in = UseHandle h2}
    (_, Just h4, _, _) <- createProcess (shell "cut -d' ' -f1") {std_out = CreatePipe, std_in = UseHandle h3}
    objectLines <- hGetContents h4
    return $ lines (toString objectLines)

readHashObject :: String -> Ref -> Expectation
readHashObject path sha1 =
    readObject path sha1 >>= \object -> hash (storedObject object) `shouldBe` sha1