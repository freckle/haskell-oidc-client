{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

{-|
    Module: Web.OIDC.Client.Tokens
    Maintainer: krdlab@gmail.com
    Stability: experimental
-}
module Web.OIDC.Client.Tokens
    ( Tokens(..)
    , IdTokenClaims(..)
    , validateIdToken
    )
where

import           Control.Applicative                ((<|>))
import           Control.Exception                  (throwIO)
import           Control.Monad.IO.Class             (MonadIO, liftIO)
import           Data.Aeson                         (FromJSON (parseJSON),
                                                     FromJSON, Value (Object),
                                                     eitherDecode, withObject,
                                                     (.:), (.:?))
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString.Lazy.Char8         as BL
import           Data.Either                        (partitionEithers)
import           Data.Text                          (Text, pack)
import           Data.Text.Encoding                 (encodeUtf8)
import           GHC.Generics                       (Generic)
import           Jose.Jwt                           (IntDate, Jwt, JwtContent (Jwe, Jws, Unsecured))
import qualified Jose.Jwt                           as Jwt
import           Prelude                            hiding (exp)
import qualified Web.OIDC.Client.Discovery.Provider as P
import           Web.OIDC.Client.Settings           (OIDC (..))
import           Web.OIDC.Client.Types              (OpenIdException (..))

data Tokens a = Tokens
    { accessToken  :: Text
    , tokenType    :: Text
    , idToken      :: IdTokenClaims a
    , expiresIn    :: Maybe Integer
    , refreshToken :: Maybe Text
    }
  deriving (Show, Eq)

-- | Claims required for an <https://openid.net/specs/openid-connect-core-1_0.html#IDToken ID Token>,
--   plus recommended claims (nonce) and other custom claims.
data IdTokenClaims a = IdTokenClaims
    { iss         :: !Text
    , sub         :: !Text
    , aud         :: ![Text]
    , exp         :: !IntDate
    , iat         :: !IntDate
    , nonce       :: !(Maybe ByteString)
    , otherClaims :: !a
    }
  deriving (Show, Eq, Generic)

instance FromJSON a => FromJSON (IdTokenClaims a) where
    parseJSON = withObject "IdTokenClaims" $ \o ->
        IdTokenClaims
            <$> o .: "iss"
            <*> o .: "sub"
            <*> (o .: "aud" <|> ((:[]) <$> (o .: "aud")))
            <*> o .: "exp"
            <*> o .: "iat"
            <*> (fmap encodeUtf8 <$> o .:? "nonce")
            <*> parseJSON (Object o)

validateIdToken :: (MonadIO m, FromJSON a) => OIDC -> Jwt -> m (IdTokenClaims a)
validateIdToken oidc jwt' = do
    let jwks  = P.jwkSet . oidcProvider $ oidc
        token = Jwt.unJwt jwt'
        alg =
            fmap (Jwt.JwsEncoding . P.getJwsAlg)
                . P.idTokenSigningAlgValuesSupported
                . P.configuration
                $ oidcProvider oidc
    decoded <-
        (\x -> case partitionEithers x of
                (_, k : _) -> Right k
                (e : _, _) -> Left e
                ([], []) -> Left $ Jwt.KeyError "No Keys available for decoding"
            )
            <$> traverse
                    (\alg' -> liftIO $ Jwt.decode jwks (Just alg') token)
                    alg
    case decoded of
        Right (Unsecured payload) -> liftIO . throwIO $ UnsecuredJwt payload
        Right (Jws (_header, payload)) -> parsePayload payload
        Right (Jwe (_header, payload)) -> parsePayload payload
        Left err -> liftIO . throwIO $ JwtExceptoin err
  where
    parsePayload payload = case eitherDecode $ BL.fromStrict payload of
        Right x   -> return x
        Left  err -> liftIO . throwIO . JsonException $ pack err
