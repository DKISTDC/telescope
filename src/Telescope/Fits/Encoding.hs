module Telescope.Fits.Encoding where

import Control.Exception (Exception)
import Control.Monad.Catch (MonadThrow, throwM)
import Data.ByteString qualified as BS
import Data.ByteString.Builder
import Data.ByteString.Lazy qualified as BL
import Data.Char (toUpper)
import Data.Fits qualified as Fits
import Data.Fits.MegaParser qualified as Fits
import Data.Fits.Read (FitsError (..))
import Data.String (IsString (..))
import Data.Text (Text, isPrefixOf, pack, unpack)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Telescope.Fits.Checksum
import Telescope.Fits.Types
import Text.Megaparsec qualified as M


{- | Decode a FITS file read as a strict 'ByteString'

>  decode =<< BS.readFile "samples/simple2x3.fits"
-}
decode :: forall m. (MonadThrow m) => BS.ByteString -> m Fits
decode inp = do
  hdus <- either (throwM . FormatError . ParseError) pure $ M.runParser Fits.parseHDUs "FITS" inp
  case hdus of
    [] -> throwM MissingPrimary
    (h : hs) -> do
      primaryHDU <- toPrimary h
      extensions <- mapM toExtension hs
      pure $ Fits{primaryHDU, extensions}
 where
  toExtension :: Fits.HeaderDataUnit -> m Extension
  toExtension hdu =
    case hdu._extension of
      Fits.Primary -> throwM $ InvalidExtension "Primary, expected Extension"
      Fits.Image -> pure $ Image $ ImageHDU hdu._header $ dataArray hdu
      Fits.BinTable n heap -> pure $ BinTable $ BinTableHDU hdu._header n heap (dataArray hdu)
  -- ex -> throwM $ InvalidExtension (show ex)

  toPrimary :: Fits.HeaderDataUnit -> m PrimaryHDU
  toPrimary hdu =
    case hdu._extension of
      Fits.Primary -> pure $ PrimaryHDU hdu._header $ dataArray hdu
      _ -> throwM $ InvalidExtension "Extension, expected Primary"

  dataArray :: Fits.HeaderDataUnit -> DataArray
  dataArray hdu =
    DataArray
      { bitpix = bitpix hdu._dimensions._bitpix
      , axes = axes hdu._dimensions._axes
      , rawData = hdu._mainData
      }

  -- decodePrimary :: BS.ByteString -> m PrimaryHDU
  -- decodePrimary inp =
  -- toImage :: Fits.HeaderDataUnit -> m ImageHDU

  bitpix :: Fits.BitPixFormat -> BitPix
  bitpix Fits.EightBitInt = BPInt8
  bitpix Fits.SixteenBitInt = BPInt16
  bitpix Fits.ThirtyTwoBitInt = BPInt32
  bitpix Fits.SixtyFourBitInt = BPInt64
  bitpix Fits.ThirtyTwoBitFloat = BPFloat
  bitpix Fits.SixtyFourBitFloat = BPDouble

  axes :: Fits.Axes -> Axes Column
  axes = Axes


data HDUError
  = InvalidExtension String
  | MissingPrimary
  | FormatError FitsError
  deriving (Show, Exception)


{- | Encode a FITS file to a strict 'ByteString'

> BS.writeFile $ encdoe fits
-}
encode :: Fits -> BS.ByteString
encode f =
  let primary = renderPrimaryHDU f.primaryHDU
      exts = fmap renderExtensionHDU f.extensions
   in mconcat $ fmap (writeChecksum . BS.toStrict . runRender) $ primary : exts


-- | Write the CHECKSUM header, assumes you have already set DATASUM and CHECKSUM=0
writeChecksum :: BS.ByteString -> BS.ByteString
writeChecksum hdu =
  replaceChecksum (checksum hdu) hdu
 where
  replaceChecksum :: Checksum -> BS.ByteString -> BS.ByteString
  replaceChecksum csum = replaceKeywordLine "CHECKSUM" (String $ encodeChecksum csum)

  replaceKeywordLine :: BS.ByteString -> Value -> BS.ByteString -> BS.ByteString
  replaceKeywordLine key val header =
    let (start, rest) = BS.breakSubstring key header
        newKeyLine = BS.toStrict $ runRender $ renderKeywordLine (TE.decodeUtf8 key) val Nothing
     in start <> newKeyLine <> BS.drop 80 rest


-- | Execute a BuilderBlock and create a bytestring
runRender :: BuilderBlock -> BL.ByteString
runRender bb = toLazyByteString bb.builder


renderPrimaryHDU :: PrimaryHDU -> BuilderBlock
renderPrimaryHDU hdu =
  let dsum = checksum hdu.dataArray.rawData
   in mconcat
        [ renderPrimaryHeader hdu.dataArray.bitpix hdu.dataArray.axes dsum hdu.header
        , renderData hdu.dataArray.rawData
        ]


renderExtensionHDU :: Extension -> BuilderBlock
renderExtensionHDU (Image hdu) = renderImageHDU hdu
renderExtensionHDU (BinTable _) = error "BinTableHDU rendering not supported"


renderImageHDU :: ImageHDU -> BuilderBlock
renderImageHDU hdu =
  let dsum = checksum hdu.dataArray.rawData
   in mconcat
        [ renderImageHeader hdu.dataArray.bitpix hdu.dataArray.axes dsum hdu.header
        , renderData hdu.dataArray.rawData
        ]


renderData :: BS.ByteString -> BuilderBlock
renderData s = fillBlock zeros $ BuilderBlock (BS.length s) $ byteString s


renderImageHeader :: BitPix -> Axes Column -> Checksum -> Header -> BuilderBlock
renderImageHeader bp as dsum h =
  fillBlock spaces $
    mconcat
      [ renderKeywordLine "XTENSION" (String "IMAGE") (Just "Image Extension")
      , renderDataKeywords bp as
      , renderKeywordLine "PCOUNT" (Integer 0) Nothing
      , renderKeywordLine "GCOUNT" (Integer 1) Nothing
      , renderDatasum dsum
      , renderOtherKeywords h
      , renderEnd
      ]


renderPrimaryHeader :: BitPix -> Axes Column -> Checksum -> Header -> BuilderBlock
renderPrimaryHeader bp as dsum h =
  fillBlock spaces $
    mconcat
      [ renderKeywordLine "SIMPLE" (Logic T) (Just "Conforms to the FITS standard")
      , renderDataKeywords bp as
      , renderKeywordLine "EXTEND" (Logic T) Nothing
      , renderDatasum dsum
      , renderOtherKeywords h
      , renderEnd
      ]


renderDatasum :: Checksum -> BuilderBlock
renderDatasum dsum =
  mconcat
    [ renderKeywordLine "DATASUM" (checksumValue dsum) Nothing
    , -- encode the CHECKSUM as zeros, replace later in 'runRenderHDU'
      renderKeywordLine "CHECKSUM" (String (T.replicate 16 "0")) Nothing
    ]


renderEnd :: BuilderBlock
renderEnd = pad 80 "END"


-- | Render required keywords for a data array
renderDataKeywords :: BitPix -> Axes Column -> BuilderBlock
renderDataKeywords bp (Axes as) =
  mconcat
    [ bitpix
    , naxis_
    , naxes
    ]
 where
  bitpix = renderKeywordLine "BITPIX" (Integer $ bitPixCode bp) (Just $ "(" <> bitPixType bp <> ") array data type")
  naxis_ = renderKeywordLine "NAXIS" (Integer $ length as) (Just "number of axes in data array")
  naxes = mconcat $ zipWith @Int naxisN [1 ..] as
  naxisN n a =
    let nt = pack (show n)
     in renderKeywordLine ("NAXIS" <> nt) (Integer a) (Just $ "axis " <> nt <> " length")
  bitPixType = pack . drop 2 . show


-- | 'Header' contains all other keywords. Filter out any that match system keywords so they aren't rendered twice
renderOtherKeywords :: Header -> BuilderBlock
renderOtherKeywords (Header ks) =
  mconcat $ map toLine $ filter (not . isSystemKeyword) ks
 where
  toLine (Keyword kr) = renderKeywordLine kr._keyword kr._value kr._comment
  toLine (Comment c) = pad 80 $ string $ "COMMENT " <> unpack c
  toLine BlankLine = pad 80 ""
  isSystemKeyword (Keyword kr) =
    let k = kr._keyword
     in k == "BITPIX"
          || k == "EXTEND"
          || k == "DATASUM"
          || k == "CHECKSUM"
          || "NAXIS" `isPrefixOf` k
  isSystemKeyword _ = False


-- | Fill out the header or data block to the nearest 2880 bytes
fillBlock :: (Int -> BuilderBlock) -> BuilderBlock -> BuilderBlock
fillBlock fill b =
  let rm = hduBlockSize - b.length `mod` hduBlockSize
   in b <> extraSpaces rm
 where
  extraSpaces n
    | n == hduBlockSize = mempty
    | otherwise = fill n


bitPixCode :: BitPix -> Int
bitPixCode BPInt8 = 8
bitPixCode BPInt16 = 16
bitPixCode BPInt32 = 32
bitPixCode BPInt64 = 64
bitPixCode BPFloat = -32
bitPixCode BPDouble = -64


-- Keyword Lines -----------------------------------------------------

renderKeywordLine :: Text -> Value -> Maybe Text -> BuilderBlock
renderKeywordLine k v mc =
  let kv = renderKeywordValue k v
   in pad 80 $ addComment kv mc
 where
  addComment kv Nothing = kv
  addComment kv (Just c) =
    let mx = 80 - kv.length
     in kv <> renderComment mx c


renderKeywordValue :: Text -> Value -> BuilderBlock
renderKeywordValue k v =
  mconcat
    [ renderKeyword k
    , string "= "
    , pad 20 $ renderValue v
    ]


renderKeyword :: Text -> BuilderBlock
renderKeyword k = pad 8 $ string $ map toUpper $ take 8 $ unpack k


renderComment :: Int -> Text -> BuilderBlock
renderComment mx c = string $ take mx $ " / " <> unpack c


renderValue :: Value -> BuilderBlock
renderValue (Logic T) = justify 20 "T"
renderValue (Logic F) = justify 20 "F"
renderValue (Float f) = justify 20 $ string $ map toUpper $ show f
renderValue (Integer n) = justify 20 $ string $ show n
renderValue (String s) = string $ "'" <> unpack s <> "'"


-- Builder Block ---------------------------------------------------------

-- | We need a builder that keeps track of its length so we can pad things
data BuilderBlock = BuilderBlock {length :: Int, builder :: Builder}


-- | Smart constructor, don't allow negative lengths
builderBlock :: Int -> Builder -> BuilderBlock
builderBlock n = BuilderBlock (max n 0)


instance IsString BuilderBlock where
  fromString = string


instance Semigroup BuilderBlock where
  BuilderBlock l b <> BuilderBlock l2 b2 = BuilderBlock (l + l2) (b <> b2)


instance Monoid BuilderBlock where
  mempty = BuilderBlock 0 mempty


justify :: Int -> BuilderBlock -> BuilderBlock
justify n b = spaces (n - b.length) <> b


pad :: Int -> BuilderBlock -> BuilderBlock
pad n b = b <> spaces (n - b.length)


spaces :: Int -> BuilderBlock
spaces = padding (charUtf8 ' ')


zeros :: Int -> BuilderBlock
zeros = padding (word8 0)


padding :: Builder -> Int -> BuilderBlock
padding b n = builderBlock n . mconcat . replicate n $ b


string :: String -> BuilderBlock
string s = builderBlock (length s) (stringUtf8 s)
