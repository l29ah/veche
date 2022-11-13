{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- @
-- do  manager <- newTlsManager
--     eResult <- runClientM req $ mkClientEnv manager publicServerBase
--     either throwIO pure eResult
-- @
module Stellar.Horizon.Client (
    -- * Types
    Account (..),
    Address (..),
    Asset (..),
    assetFromText,
    assetToText,
    xlm,
    Memo (..),
    Operation (..),
    Signer (..),
    Transaction (..),
    TransactionOnChain (..),
    transactionFromDto,
    transactionFromEnvelopeXdr,
    TxId (..),
    -- * Endpoints
    publicServerBase,
    testServerBase,
    -- * Methods
    getAccount,
    getAccounts,
    getAccountTransactionsDto,
    getAccountsList,
    getAccountTransactionsDtoList,
    getAccountTransactionsList,
    submitTransaction,
    -- * Helpers
    decodeUtf8Throw,
) where

import Prelude hiding (id, last)
import Prelude qualified

-- global
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Int (Int64)
import Data.List.NonEmpty (last, nonEmpty)
import Data.Scientific (Scientific, scientific)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import GHC.Stack (HasCallStack)
import Numeric.Natural (Natural)
import Servant.API ((:<|>) ((:<|>)))
import Servant.Client (BaseUrl, ClientM, client, parseBaseUrl)
import System.IO.Unsafe (unsafePerformIO)

-- stellar-sdk
import Network.ONCRPC.XDR (xdrDeserialize)
import Network.ONCRPC.XDR qualified as XDR
import Network.Stellar.Keypair qualified as StellarKey
import Network.Stellar.TransactionXdr qualified as XDR

-- component
import Data.Foldable (toList)
import Stellar.Horizon.API (TxText, api)
import Stellar.Horizon.DTO (Account (..), Address (..), Record (Record),
                            Records (Records), Signer (..), TxId (..))
import Stellar.Horizon.DTO qualified as DTO
import Stellar.Simple.Types (Asset (..), Memo (..), Operation (..),
                             PaymentType (DirectPayment, PathPayment), Shown,
                             Transaction (..), TransactionOnChain (..),
                             assetFromText, assetToText, shown)

identity :: a -> a
identity = Prelude.id

-- | Public network Horizon server https://horizon.stellar.org/
publicServerBase :: BaseUrl
publicServerBase = unsafePerformIO $ parseBaseUrl "https://horizon.stellar.org/"
{-# NOINLINE publicServerBase #-}

-- | Test network Horizon server https://horizon-testnet.stellar.org/
testServerBase :: BaseUrl
testServerBase =
    unsafePerformIO $ parseBaseUrl "https://horizon-testnet.stellar.org/"
{-# NOINLINE testServerBase #-}

getAccounts ::
    Maybe Asset -> Maybe Text -> Maybe Natural -> ClientM (Records Account)
getAccount :: Address -> ClientM Account
getAccountTransactionsDto ::
    Address -> Maybe Text -> Maybe Natural -> ClientM (Records DTO.Transaction)
submitTransaction :: TxText -> ClientM DTO.Transaction
(               getAccounts
        :<|>    getAccount
        :<|>    getAccountTransactionsDto
        :<|>    submitTransaction
        ) =
    client api

getAccountsList :: Asset -> ClientM [Account]
getAccountsList = recordsToList . getAccounts . Just

getAccountTransactionsDtoList :: Address -> ClientM [DTO.Transaction]
getAccountTransactionsDtoList = recordsToList . getAccountTransactionsDto

getAccountTransactionsList ::
    HasCallStack => Address -> ClientM [TransactionOnChain]
getAccountTransactionsList =
    fmap (map transactionFromDto) . getAccountTransactionsDtoList

recordsToList ::
    (Maybe Text -> Maybe Natural -> ClientM (Records a)) -> ClientM [a]
recordsToList endpoint = go Nothing where
    limit = 200
    go cursor = do
        Records records <- endpoint cursor (Just limit)
        let values = map (\Record{value} -> value) records
        case nonEmpty records of
            Just neRecords | length records == fromIntegral limit ->
                let Record{paging_token} = last neRecords
                in (values <>) <$> go (Just paging_token)
            _ -> pure values

transactionFromDto :: HasCallStack => DTO.Transaction -> TransactionOnChain
transactionFromDto DTO.Transaction{created_at, envelope_xdr, id} =
    TransactionOnChain
        {id, time = created_at, tx = transactionFromEnvelopeXdr envelope}
  where
    envelopeXdrRaw =
        either error identity $ Base64.decode $ encodeUtf8 envelope_xdr
    envelope = either error identity $ xdrDeserialize envelopeXdrRaw

transactionFromEnvelopeXdr :: XDR.TransactionEnvelope -> Transaction
transactionFromEnvelopeXdr = \case
    XDR.TransactionEnvelope'ENVELOPE_TYPE_TX_V0       e -> fromV0 e
    XDR.TransactionEnvelope'ENVELOPE_TYPE_TX          e -> fromV1 e
    XDR.TransactionEnvelope'ENVELOPE_TYPE_TX_FEE_BUMP e -> fromFB e
  where

    fromV0  (XDR.TransactionV0Envelope
                XDR.TransactionV0
                    { transactionV0'memo
                    , transactionV0'operations
                    , transactionV0'sourceAccountEd25519
                    }
                _signatures
            ) =
        Transaction
            { memo          = memoFromXdr transactionV0'memo
            , operations    = operationsFromXdr transactionV0'operations
            , source =
                Address $
                StellarKey.encodePublic $
                XDR.unLengthArray transactionV0'sourceAccountEd25519
            }

    fromV1  (XDR.TransactionV1Envelope
                XDR.Transaction
                    { transaction'memo
                    , transaction'operations
                    , transaction'sourceAccount
                    }
                _signatures
            ) =
        Transaction
            { memo          = memoFromXdr transaction'memo
            , operations    = operationsFromXdr transaction'operations
            , source        = addressFromXdrMuxed transaction'sourceAccount
            }

    fromFB  (XDR.FeeBumpTransactionEnvelope
                XDR.FeeBumpTransaction{feeBumpTransaction'feeSource} _signatures
            ) =
        Transaction
            { memo          = MemoNone
            , operations    = []
            , source        = addressFromXdrMuxed feeBumpTransaction'feeSource
            }

    operationsFromXdr ::
        XDR.Array n XDR.Operation -> [Either (Shown XDR.Operation) Operation]
    operationsFromXdr =
        map (\xop -> maybe (Left $ shown xop) Right $ operationFromXdr xop)
        . toList
        . XDR.unLengthArray

memoFromXdr :: XDR.Memo -> Memo
memoFromXdr = \case
    XDR.Memo'MEMO_NONE -> MemoNone
    XDR.Memo'MEMO_TEXT text ->
        MemoText $ decodeUtf8Throw $ XDR.unLengthArray text
    memo -> MemoOther $ shown memo

addressFromXdrMuxed :: XDR.MuxedAccount -> Address
addressFromXdrMuxed =
    Address
    . StellarKey.encodePublic
    . XDR.unLengthArray
    . \case
        XDR.MuxedAccount'KEY_TYPE_ED25519 address -> address
        XDR.MuxedAccount'KEY_TYPE_MUXED_ED25519 _id address -> address

operationFromXdr :: XDR.Operation -> Maybe Operation
operationFromXdr XDR.Operation{operation'body, operation'sourceAccount} =
    case operation'body of
        XDR.OperationBody'CHANGE_TRUST{} -> Just OperationChangeTrust
        XDR.OperationBody'CREATE_ACCOUNT{} -> Just OperationCreateAccount
        XDR.OperationBody'CREATE_CLAIMABLE_BALANCE{} ->
            Just OperationCreateClaimableBalance
        XDR.OperationBody'MANAGE_DATA (XDR.ManageDataOp name mvalue) ->
            OperationManageData
            <$> either
                    (const Nothing) Just (decodeUtf8' $ XDR.unLengthArray name)
            <*> case mvalue of
                    Nothing -> Just Nothing
                    Just array ->
                        either (const Nothing) (Just . Just) $
                        decodeUtf8' $ XDR.unLengthArray array
        XDR.OperationBody'PATH_PAYMENT_STRICT_RECEIVE
                XDR.PathPaymentStrictReceiveOp
                    { pathPaymentStrictReceiveOp'destAmount
                    , pathPaymentStrictReceiveOp'destAsset
                    , pathPaymentStrictReceiveOp'destination
                    } ->
            Just
            OperationPayment
                { amount = amountFromXdr pathPaymentStrictReceiveOp'destAmount
                , asset  = assetFromXdr  pathPaymentStrictReceiveOp'destAsset
                , destination =
                    addressFromXdrMuxed pathPaymentStrictReceiveOp'destination
                , source
                , type_ = PathPayment
                }
        XDR.OperationBody'PAYMENT
                XDR.PaymentOp
                    { paymentOp'amount
                    , paymentOp'asset
                    , paymentOp'destination
                    } ->
            Just
            OperationPayment
                { amount        = amountFromXdr         paymentOp'amount
                , asset         = assetFromXdr          paymentOp'asset
                , destination   = addressFromXdrMuxed   paymentOp'destination
                , source
                , type_ = DirectPayment
                }
        XDR.OperationBody'SET_OPTIONS{} -> Just OperationSetOptions
        _ -> Nothing
  where
    source = addressFromXdr <$> operation'sourceAccount

decodeUtf8Throw :: HasCallStack => ByteString -> Text
decodeUtf8Throw = either (error . show) identity . decodeUtf8'

amountFromXdr :: Int64 -> Scientific
amountFromXdr i = scientific (fromIntegral i) (-7)

assetFromXdr :: XDR.Asset -> Asset
assetFromXdr = \case
    XDR.Asset'ASSET_TYPE_NATIVE -> xlm
    XDR.Asset'ASSET_TYPE_CREDIT_ALPHANUM4 (XDR.AlphaNum4 code issuer) ->
        assetAlphaNum code issuer
    XDR.Asset'ASSET_TYPE_CREDIT_ALPHANUM12 (XDR.AlphaNum12 code issuer) ->
        assetAlphaNum code issuer
  where
    assetAlphaNum code (XDR.PublicKey'PUBLIC_KEY_TYPE_ED25519 issuer) =
        Asset
            { code =
                decodeUtf8Throw $
                BS.dropWhileEnd (== 0) $ XDR.unLengthArray code
            , issuer = Just $ StellarKey.encodePublic $ XDR.unLengthArray issuer
            }

addressFromXdr :: XDR.AccountID -> Address
addressFromXdr (XDR.PublicKey'PUBLIC_KEY_TYPE_ED25519 address) =
    Address $ StellarKey.encodePublic $ XDR.unLengthArray address

-- | Native asset
xlm :: Asset
xlm = Asset{code = "XLM", issuer = Nothing}
