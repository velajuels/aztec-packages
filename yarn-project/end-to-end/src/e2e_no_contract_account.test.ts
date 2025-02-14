import { AztecNodeService } from '@aztec/aztec-node';
import { AztecRPCServer } from '@aztec/aztec-rpc';
import { AztecAddress, BaseWallet, Wallet, generatePublicKey } from '@aztec/aztec.js';
import { CircuitsWasm, Fr, TxContext } from '@aztec/circuits.js';
import { DebugLogger } from '@aztec/foundation/log';
import { retryUntil } from '@aztec/foundation/retry';
import { PokeableTokenContract } from '@aztec/noir-contracts/types';
import { AztecRPC, ExecutionRequest, PackedArguments, TxExecutionRequest, TxStatus } from '@aztec/types';

import { randomBytes } from 'crypto';

import { expectsNumOfEncryptedLogsInTheLastBlockToBe, setup } from './utils.js';

/**
 * Wallet implementation which creates a simple transaction request without any signing.
 * @remarks Based on DeployerWallet. Used only for testing.
 */
class SignerlessWallet extends BaseWallet {
  getAddress(): AztecAddress {
    return AztecAddress.ZERO;
  }
  async createAuthenticatedTxRequest(
    executions: ExecutionRequest[],
    txContext: TxContext,
  ): Promise<TxExecutionRequest> {
    if (executions.length !== 1) {
      throw new Error(`Unexpected number of executions. Expected 1, received ${executions.length})`);
    }
    const [execution] = executions;
    const wasm = await CircuitsWasm.get();
    const packedArguments = await PackedArguments.fromArgs(execution.args, wasm);
    return Promise.resolve(
      new TxExecutionRequest(execution.to, execution.functionData, packedArguments.hash, txContext, [packedArguments]),
    );
  }
}

describe('e2e_no_contract_account', () => {
  let aztecNode: AztecNodeService | undefined;
  let aztecRpcServer: AztecRPC;
  let wallet: Wallet;
  let sender: AztecAddress;
  let recipient: AztecAddress;
  let poker: AztecAddress; // Arbitrary non-contract account
  let pokerWallet: Wallet;

  let logger: DebugLogger;

  let contract: PokeableTokenContract;

  const initialBalance = 987n;

  beforeEach(async () => {
    let accounts: AztecAddress[];
    ({ aztecNode, aztecRpcServer, accounts, wallet, logger } = await setup(2));
    sender = accounts[0];
    recipient = accounts[1];

    const pokerPrivKey = randomBytes(32);
    const pokerPubKey = await generatePublicKey(pokerPrivKey);
    poker = AztecAddress.fromBuffer(pokerPubKey.x.toBuffer());
    pokerWallet = new SignerlessWallet(aztecRpcServer);
    await pokerWallet.addAccount(pokerPrivKey, poker, new Fr(0n));

    logger(`Deploying L2 contract...`);
    const tx = PokeableTokenContract.deploy(aztecRpcServer, initialBalance, sender, recipient, pokerPubKey).send();
    const receipt = await tx.getReceipt();
    contract = new PokeableTokenContract(receipt.contractAddress!, wallet);
    await tx.isMined(0, 0.1);
    const minedReceipt = await tx.getReceipt();
    expect(minedReceipt.status).toEqual(TxStatus.MINED);
    logger('L2 contract deployed');
    return contract;
  }, 100_000);

  afterEach(async () => {
    await aztecNode?.stop();
    if (aztecRpcServer instanceof AztecRPCServer) {
      await aztecRpcServer?.stop();
    }
  });

  const expectBalance = async (owner: AztecAddress, expectedBalance: bigint) => {
    const [balance] = await contract.methods.getBalance(owner).view({ from: owner });
    logger(`Account ${owner} balance: ${balance}`);
    expect(balance).toBe(expectedBalance);
  };

  it('Arbitrary non-contract account can call a private function on a contract', async () => {
    await expectBalance(sender, initialBalance);
    await expectBalance(recipient, 0n);
    await expectsNumOfEncryptedLogsInTheLastBlockToBe(aztecNode, 3);

    const contractWithNoContractWallet = new PokeableTokenContract(contract.address, pokerWallet);

    const isUserSynchronised = async () => {
      return await wallet.isAccountSynchronised(poker);
    };
    await retryUntil(isUserSynchronised, poker.toString(), 5);

    // Send transaction as poker (arbitrary non-contract account)
    const tx = contractWithNoContractWallet.methods.poke().send({ origin: poker });

    await tx.isMined(0, 0.1);
    const receipt = await tx.getReceipt();
    expect(receipt.status).toBe(TxStatus.MINED);

    // Initial balance should be fully transferred to the recipient
    await expectBalance(sender, 0n);
    await expectBalance(recipient, initialBalance);

    await expectsNumOfEncryptedLogsInTheLastBlockToBe(aztecNode, 1);
  }, 60_000);
});
