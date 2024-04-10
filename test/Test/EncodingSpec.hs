{-# LANGUAGE TypeApplications #-}

module Test.EncodingSpec where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as C8
import Data.Massiv.Array qualified as M
import Data.Text (pack)
import Telescope.Fits qualified as Fits
import Telescope.Fits.Encoding hiding (justify, pad, spaces)
import Telescope.Fits.Encoding.DataArray
import Telescope.Fits.Types
import Test.Syd


spec :: Spec
spec = do
  describe "decode fits" testDecodeFits
  describe "render header" testRenderHeader
  describe "render data" testRenderData
  describe "encode primary" testEncodePrimary
  describe "round trip" testRoundTrip


testDecodeFits :: Spec
testDecodeFits = do
  describe "simple2x3.fits" $ do
    it "should load load metadata" $ do
      f <- decode =<< BS.readFile "samples/simple2x3.fits"
      let dat = f.primaryHDU.dataArray
          hds = f.primaryHDU.header
      dat.axes `shouldBe` Axes [3, 2]
      dat.bitpix `shouldBe` BPInt64
      Fits.lookup "CUSTOM" hds `shouldBe` Just (Integer 123456)

    it "should load data array" $ do
      f <- decode =<< BS.readFile "samples/simple2x3.fits"
      arr <- decodeArray @Ix2 @Int f.primaryHDU.dataArray
      M.toLists arr `shouldBe` [[0, 1, 2], [3, 4, 5]]


testRenderHeader :: Spec
testRenderHeader = do
  describe "renderValue" $ do
    it "int should right justify" $ do
      runValue (Integer 8) `shouldBe` justify 30 "8"

    it "float should right justify" $ do
      runValue (Float 3.2) `shouldBe` justify 30 "3.2"

    it "negative int" $ do
      runValue (Integer (-32)) `shouldBe` justify 30 "-32"

    it "negative float" $ do
      runValue (Float (-32.32)) `shouldBe` justify 30 "-32.32"

    it "float should exponent uppercase" $ do
      runValue (Float 6.0001e-16) `shouldBe` justify 30 "6.0001E-16"

    it "logic should right justify" $ do
      runValue (Logic T) `shouldBe` justify 30 "T"

    it "string" $ do
      runValue (String "Hello World") `shouldBe` "'Hello World'"

  -- describe "render entire header" $ do

  -- TODO: does it matter if e-06 vs e-6? We output e-6.

  describe "renderKeyword" $ do
    it "should left justify" $ do
      run (renderKeyword "BITPIX") `shouldBe` "BITPIX  "

    it "should truncate" $ do
      run (renderKeyword "REALLYLONG") `shouldBe` "REALLYLO"

    it "should uppercase" $ do
      run (renderKeyword "lower") `shouldBe` "LOWER   "

  describe "renderKeywordValue" $ do
    it "should render space" $ do
      run (renderKeywordValue "SIMPLE" (Logic T)) `shouldBe` ("SIMPLE  = " <> justify 30 "T")

    it "should butt against equals" $ do
      run (renderKeywordValue "WHATEVER" (Integer 10)) `shouldBe` ("WHATEVER= " <> justify 30 "10")

    it "should string" $ do
      run (renderKeywordValue "WHATEVER" (String "dude")) `shouldBe` pad 40 "WHATEVER= 'dude'"

  describe "renderComment" $ do
    it "should render comment" $ do
      run (renderComment 100 "Hello World") `shouldBe` " / Hello World"

    it "should truncate comment" $ do
      run (renderComment 10 "Hello World") `shouldBe` " / Hello W"

  describe "renderKeywordComments" $ do
    it "should render comment in line" $ do
      run (renderKeywordLine "SIMPLE" (Logic T) (Just "Comment")) `shouldBe` pad 80 ("SIMPLE  = " <> justify 30 "T" <> " / Comment")

    it "should render no comment" $ do
      run (renderKeywordLine "SIMPLE" (Logic T) Nothing) `shouldBe` pad 80 ("SIMPLE  = " <> justify 30 "T")

    it "should truncate whole line" $ do
      run (renderKeywordLine "SIMPLE" (Logic T) Nothing) `shouldBe` pad 80 ("SIMPLE  = " <> justify 30 "T")

  describe "renderKeywordLine" $ do
    it "should be 80 characters mininum" $ do
      let b = renderKeywordLine "HELLO" (Integer 1) Nothing
      b.length `shouldBe` 80

    it "should be 80 characters maximum" $ do
      let b = renderKeywordLine "HELLO" (Integer 1) (Just $ pack $ replicate 100 'a')
      b.length `shouldBe` 80

    it "should be padded" $ do
      run (renderKeywordLine "HELLO" (Integer 1) Nothing) `shouldBe` "HELLO   = " <> justify 30 "1" <> spaces 40
 where
  run :: BuilderBlock -> String
  run = C8.unpack . runRender

  runValue :: Value -> String
  runValue = run . renderValue


justify :: Int -> String -> String
justify n s = spaces (n - length s) <> s


pad :: Int -> String -> String
pad n s = s <> spaces (n - length s)


spaces :: Int -> String
spaces n = replicate n ' '


testRenderData :: Spec
testRenderData = do
  it "fill block should fill" $ do
    (fillBlock "a").length `shouldBe` 2880
    (fillBlock "hello world").length `shouldBe` 2880
    (fillBlock "").length `shouldBe` 0

  it "should be empty" $ do
    runRender (renderData "") `shouldBe` ""

  it "should pad to nearest block" $ do
    (renderData "asdf").length `shouldBe` 2880


testEncodePrimary :: Spec
testEncodePrimary = do
  aroundAll provEncoded $ describe "encoded primary hdu" $ do
    itWithOuter "encodes a header and data hdu" $ \enc -> do
      BS.length enc == hduBlockSize * 2

    itWithOuter "starts with SIMPLE" $ \enc -> do
      BS.take 40 enc `shouldBe` "SIMPLE  =                              T"

  aroundAll provDecoded $ describe "decoded encoded primary hdu" $ do
    itWithOuter "Has custom header" $ \f -> do
      Fits.lookup "WOOT" f.primaryHDU.header `shouldBe` Just (Integer 123)

    itWithOuter "Has required headers" $ \f -> do
      Fits.lookup "EXTEND" f.primaryHDU.header `shouldBe` Just (Logic T)

    itWithOuter "Matches data metadata" $ \f -> do
      f.primaryHDU.dataArray.bitpix `shouldBe` BPInt8
      f.primaryHDU.dataArray.axes `shouldBe` Axes [3, 2]

    itWithOuter "Matches raw data" $ \f -> do
      f.primaryHDU.dataArray.rawData `shouldBe` BS.pack [0 .. 5]
 where
  primary =
    let heads = Header [Keyword $ KeywordRecord "WOOT" (Integer 123) Nothing]
        dat = DataArray BPInt8 (Axes [3, 2]) $ BS.pack [0 .. 5]
        hdu = PrimaryHDU heads dat
     in hdu

  provEncoded m = do
    m $ encode (Fits primary [])

  provDecoded m = do
    let enc = encode (Fits primary [])
    f <- decode enc
    m f


testRoundTrip :: Spec
testRoundTrip =
  aroundAll simple2x3 $ describe "simple2x3.fits" $ do
    itWithOuter "should match metadata" $ \fs -> do
      f2 <- decode $ encode fs
      f2.primaryHDU.dataArray.axes `shouldBe` Axes [3, 2]
      f2.primaryHDU.dataArray.bitpix `shouldBe` fs.primaryHDU.dataArray.bitpix

    itWithOuter "should match raw data" $ \fs -> do
      f2 <- decode $ encode fs
      f2.primaryHDU.dataArray.rawData `shouldBe` fs.primaryHDU.dataArray.rawData

    itWithOuter "should encode headers only once" $ \fs -> do
      f2 <- decode $ encode fs
      let hs = fs.primaryHDU.header
          h2 = f2.primaryHDU.header
      Fits.lookup "NAXIS" h2 `shouldBe` Just (Integer 2)

      let ks = getKeywords hs
          k2 = getKeywords h2

      filter (isKeyword "BITPIX") k2 `shouldBe` filter (isKeyword "BITPIX") ks

      length hs._records `shouldBe` length h2._records
 where
  isKeyword k (k2, _) = k == k2


-- hs `shouldBe` h2

simple2x3 :: (Fits -> IO a) -> IO a
simple2x3 m = do
  inp <- BS.readFile "samples/simple2x3.fits"
  fits <- decode inp
  m fits
