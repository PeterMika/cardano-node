module Cardano.CLI.Shelley.Run.Governance
  ( ShelleyGovernanceError
  , renderShelleyGovernanceError
  , runGovernanceCmd
  ) where

import           Cardano.Prelude

import qualified Data.Text as Text

import           Control.Monad.Trans.Except (ExceptT)
import           Control.Monad.Trans.Except.Extra (firstExceptT, left, newExceptT, right)

import           Cardano.Api.TextView (TextViewDescription (..), textShow)
import           Cardano.Api.Typed

import           Cardano.CLI.Shelley.Commands (VerificationKeyOrHashOrFile (..))
import           Cardano.CLI.Shelley.Parsers
import           Cardano.CLI.Types

import qualified Shelley.Spec.Ledger.TxData as Shelley


data ShelleyGovernanceError
  = GovernanceReadFileError !(FileError TextEnvelopeError)
  | GovernanceWriteFileError !(FileError ())
  | GovernanceEmptyUpdateProposalError
  | GovernanceMIRCertificateKeyRewardMistmach
      !FilePath
      !Int
      -- ^ Number of stake verification keys
      !Int
      -- ^ Number of reward amounts
  deriving Show

renderShelleyGovernanceError :: ShelleyGovernanceError -> Text
renderShelleyGovernanceError err =
  case err of
    GovernanceReadFileError fileErr -> Text.pack (displayError fileErr)
    GovernanceWriteFileError fileErr -> Text.pack (displayError fileErr)
    -- TODO: The equality check is still not working for empty update proposals.
    GovernanceEmptyUpdateProposalError ->
      "Empty update proposals are not allowed"
    GovernanceMIRCertificateKeyRewardMistmach fp numVKeys numRwdAmts ->
       "Error creating the MIR certificate at: " <> textShow fp
       <> " The number of staking keys: " <> textShow numVKeys
       <> " and the number of reward amounts: " <> textShow numRwdAmts
       <> " are not equivalent."



runGovernanceCmd :: GovernanceCmd -> ExceptT ShelleyGovernanceError IO ()
runGovernanceCmd (GovernanceMIRCertificate mirpot vKeys rewards out) =
  runGovernanceMIRCertificate mirpot vKeys rewards out
runGovernanceCmd (GovernanceGenesisKeyDelegationCertificate genVk genDelegVk vrfVk out) =
  runGovernanceGenesisKeyDelegationCertificate genVk genDelegVk vrfVk out
runGovernanceCmd (GovernanceUpdateProposal out eNo genVKeys ppUp) =
  runGovernanceUpdateProposal out eNo genVKeys ppUp

runGovernanceMIRCertificate
  :: Shelley.MIRPot
  -> [VerificationKeyFile]
  -- ^ Stake verification keys
  -> [Lovelace]
  -- ^ Reward amounts
  -> OutputFile
  -> ExceptT ShelleyGovernanceError IO ()
runGovernanceMIRCertificate mirPot vKeys rwdAmts (OutputFile oFp) = do
    sCreds <- mapM readStakeKeyToCred vKeys

    checkEqualKeyRewards vKeys rwdAmts

    let mirCert = makeMIRCertificate mirPot (zip sCreds rwdAmts)

    firstExceptT GovernanceWriteFileError
      . newExceptT
      $ writeFileTextEnvelope oFp (Just mirCertDesc) mirCert
  where
    mirCertDesc :: TextViewDescription
    mirCertDesc = TextViewDescription "Move Instantaneous Rewards Certificate"

    checkEqualKeyRewards :: [VerificationKeyFile] -> [Lovelace] -> ExceptT ShelleyGovernanceError IO ()
    checkEqualKeyRewards keys rwds = do
       let numVKeys = length keys
           numRwdAmts = length rwds
       if numVKeys == numRwdAmts
       then return () else left $ GovernanceMIRCertificateKeyRewardMistmach oFp numVKeys numRwdAmts

    readStakeKeyToCred :: VerificationKeyFile -> ExceptT ShelleyGovernanceError IO StakeCredential
    readStakeKeyToCred (VerificationKeyFile stVKey) = do
      stakeVkey <- firstExceptT GovernanceReadFileError
        . newExceptT
        $ readFileTextEnvelope (AsVerificationKey AsStakeKey) stVKey
      right . StakeCredentialByKey $ verificationKeyHash stakeVkey

runGovernanceGenesisKeyDelegationCertificate
  :: VerificationKeyOrHashOrFile GenesisKey
  -> VerificationKeyOrHashOrFile GenesisDelegateKey
  -> VerificationKeyOrHashOrFile VrfKey
  -> OutputFile
  -> ExceptT ShelleyGovernanceError IO ()
runGovernanceGenesisKeyDelegationCertificate genVkOrHashOrFp
                                             genDelVkOrHashOrFp
                                             vrfVkOrHashOrFp
                                             (OutputFile oFp) = do
    genesisVkHash <- firstExceptT GovernanceReadFileError
      . newExceptT
      $ readVerificationKeyOrHashOrFile AsGenesisKey genVkOrHashOrFp
    genesisDelVkHash <-firstExceptT GovernanceReadFileError
      . newExceptT
      $ readVerificationKeyOrHashOrFile AsGenesisDelegateKey genDelVkOrHashOrFp
    vrfVkHash <- firstExceptT GovernanceReadFileError
      . newExceptT
      $ readVerificationKeyOrHashOrFile AsVrfKey vrfVkOrHashOrFp
    firstExceptT GovernanceWriteFileError
      . newExceptT
      $ writeFileTextEnvelope oFp (Just genKeyDelegCertDesc)
      $ makeGenesisKeyDelegationCertificate genesisVkHash genesisDelVkHash vrfVkHash
  where
    genKeyDelegCertDesc :: TextViewDescription
    genKeyDelegCertDesc = TextViewDescription "Genesis Key Delegation Certificate"

runGovernanceUpdateProposal
  :: OutputFile
  -> EpochNo
  -> [VerificationKeyFile]
  -- ^ Genesis verification keys
  -> ProtocolParametersUpdate
  -> ExceptT ShelleyGovernanceError IO ()
runGovernanceUpdateProposal (OutputFile upFile) eNo genVerKeyFiles upPprams = do
    when (upPprams == mempty) $ left GovernanceEmptyUpdateProposalError
    genVKeys <- sequence
                  [ firstExceptT GovernanceReadFileError . newExceptT $
                      readFileTextEnvelope
                        (AsVerificationKey AsGenesisKey)
                        vkeyFile
                  | VerificationKeyFile vkeyFile <- genVerKeyFiles ]
    let genKeyHashes = map verificationKeyHash genVKeys
        upProp = makeShelleyUpdateProposal upPprams genKeyHashes eNo
    firstExceptT GovernanceWriteFileError . newExceptT $
      writeFileTextEnvelope upFile Nothing upProp

-- | Read a verification key or verification key hash or verification key file
-- and return a verification key hash.
--
-- If a filepath is provided, it will be interpreted as a text envelope
-- formatted file.
readVerificationKeyOrHashOrFile
  :: Key keyrole
  => AsType keyrole
  -> VerificationKeyOrHashOrFile keyrole
  -> IO (Either (FileError TextEnvelopeError) (Hash keyrole))
readVerificationKeyOrHashOrFile asType verKeyOrHashOrFile =
  case verKeyOrHashOrFile of
    VerificationKeyHash vkHash -> pure (Right vkHash)
    VerificationKeyValue vk -> pure (Right $ verificationKeyHash vk)
    VerificationKeyFilePath (VerificationKeyFile fp) -> do
      eitherVk <- readFileTextEnvelope (AsVerificationKey asType) fp
      pure (verificationKeyHash <$> eitherVk)
