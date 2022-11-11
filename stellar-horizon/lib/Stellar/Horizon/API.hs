{-# OPTIONS -Wno-orphans #-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Stellar.Horizon.API (API, api, TxText (..)) where

import Data.Aeson (FromJSON, ToJSON)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Proxy (Proxy (Proxy))
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Media ((//), (/:))
import Network.HTTP.Types (urlEncodeBuilder)
import Numeric.Natural (Natural)
import Servant.API (Accept, Capture, FromHttpApiData, Get, JSON, MimeRender,
                    MimeUnrender, Post, QueryParam, QueryParam', Required,
                    Strict, ToHttpApiData, mimeRender, mimeUnrender,
                    toQueryParam, (:<|>), (:>))
import Servant.API qualified
import Servant.Docs (DocCapture (DocCapture), DocQueryParam (DocQueryParam),
                     ParamKind (Normal), ToCapture, ToParam)
import Servant.Docs qualified

import Stellar.Horizon.DTO (Account, Address, Records, Transaction)
import Stellar.Simple.Types (Asset)

data HalJson

instance Accept HalJson where
    contentTypes _ =
        "application" // "hal+json" /: ("charset", "utf-8")
        :| ["application" // "hal+json"]

instance FromJSON a => MimeUnrender HalJson a where
    mimeUnrender _ = mimeUnrender (Proxy @JSON)

instance ToJSON a => MimeRender HalJson a where
    mimeRender _ = mimeRender (Proxy @JSON)

type QueryParamR = QueryParam' [Required, Strict]

-- | TODO hack before url encoding is fixed in servant
-- waiting https://github.com/fizruk/http-api-data/commit/5b01eee1d5dcd4e2c981c58fd33afb96e1b29ca6 to be released
-- http-api-data > 0.5
newtype TxText = TxText Text
    deriving newtype FromHttpApiData

instance ToHttpApiData TxText where
    toQueryParam (TxText t) = t
    toEncodedUrlPiece (TxText t) =
        urlEncodeBuilder True $ encodeUtf8 $ toQueryParam t

type API
    =   "accounts"
        :> QueryParam "asset" Asset
        :> QueryParam "cursor" Text
        :> QueryParam "limit" Natural
        :> Get '[HalJson] (Records Account)
    :<|> "accounts" :> Capture "account_id" Address :> Get '[HalJson] Account
    :<|>
        "accounts" :> Capture "account_id" Address :> "transactions"
        :> QueryParam "cursor" Text :> QueryParam "limit" Natural
        :> Get '[HalJson] (Records Transaction)
    :<|>
        "transactions" :> QueryParamR "tx" TxText :> Post '[HalJson] Transaction

api :: Proxy API
api = Proxy

instance ToCapture (Capture "account_id" Address) where
    toCapture _ =
        DocCapture
            "account_id"
            "This account’s public key\
            \ encoded in a base32 string representation."

instance ToParam (QueryParam "asset" Asset) where
    toParam _ =
        DocQueryParam
            "asset"
            []
            "An issued asset represented as “Code:IssuerAccountID”.\
            \ Every account in the response will have a trustline for the given\
            \ asset."
            Normal

instance ToParam (QueryParam "cursor" Text) where
    toParam _ =
        DocQueryParam
            "cursor"
            []
            "From official docs:\
            \ A number that points to a specific location in a collection of\
            \ responses and is pulled from the `paging_token` value of a\
            \ record.\
            \ Actually arbitrary string, not a number."
            Normal

instance ToParam (QueryParam "limit" Natural) where
    toParam _ =
        DocQueryParam
            "limit"
            []
            "The maximum number of records returned.\
            \ The limit can range from 1 to 200 -\
            \ an upper limit that is hardcoded in Horizon for performance\
            \ reasons.\
            \ If this argument isn’t designated, it defaults to 10."
            Normal

instance ToParam (QueryParamR "tx" TxText) where
    toParam _ =
        DocQueryParam
            "tx"
            []
            "The base64-encoded XDR of the transaction."
            Normal
