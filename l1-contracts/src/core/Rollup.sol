// SPDX-License-Identifier: Apache-2.0
// Copyright 2023 Aztec Labs.
pragma solidity >=0.8.18;

// Interfaces
import {IRollup} from "@aztec/core/interfaces/IRollup.sol";
import {IInbox} from "@aztec/core/interfaces/messagebridge/IInbox.sol";
import {IOutbox} from "@aztec/core/interfaces/messagebridge/IOutbox.sol";
import {IRegistry} from "@aztec/core/interfaces/messagebridge/IRegistry.sol";

// Libraries
import {Decoder} from "@aztec/core/libraries/Decoder.sol";
import {Errors} from "@aztec/core/libraries/Errors.sol";

// Contracts
import {MockVerifier} from "@aztec/mock/MockVerifier.sol";

/**
 * @title Rollup
 * @author Aztec Labs
 * @notice Rollup contract that are concerned about readability and velocity of development
 * not giving a damn about gas costs.
 */
contract Rollup is IRollup {
  MockVerifier public immutable VERIFIER;
  IRegistry public immutable REGISTRY;
  uint256 public immutable VERSION;

  bytes32 public rollupStateHash;
  uint256 public lastBlockTs;

  constructor(IRegistry _registry) {
    VERIFIER = new MockVerifier();
    REGISTRY = _registry;
    VERSION = 1;
  }

  /**
   * @notice Process an incoming L2Block and progress the state
   * @param _proof - The proof of correct execution
   * @param _l2Block - The L2Block data, formatted as outlined in `Decoder.sol`
   */
  function process(bytes memory _proof, bytes calldata _l2Block) external override(IRollup) {
    _constrainGlobals(_l2Block);
    (
      uint256 l2BlockNumber,
      bytes32 oldStateHash,
      bytes32 newStateHash,
      bytes32 publicInputHash,
      bytes32[] memory l2ToL1Msgs,
      bytes32[] memory l1ToL2Msgs
    ) = Decoder.decode(_l2Block);

    // @todo @LHerskind Proper genesis state. If the state is empty, we allow anything for now.
    if (rollupStateHash != bytes32(0) && rollupStateHash != oldStateHash) {
      revert Errors.Rollup__InvalidStateHash(rollupStateHash, oldStateHash);
    }

    bytes32[] memory publicInputs = new bytes32[](1);
    publicInputs[0] = publicInputHash;

    if (!VERIFIER.verify(_proof, publicInputs)) {
      revert Errors.Rollup__InvalidProof();
    }

    rollupStateHash = newStateHash;
    lastBlockTs = block.timestamp;

    // @todo (issue #605) handle fee collector
    // @todo: (issue #624) handle different versions
    IInbox inbox = REGISTRY.getInbox();
    inbox.batchConsume(l1ToL2Msgs, msg.sender);

    // @todo: (issue #624) handle different versions
    IOutbox outbox = REGISTRY.getOutbox();
    outbox.sendL1Messages(l2ToL1Msgs);

    emit L2BlockProcessed(l2BlockNumber);
  }

  function _constrainGlobals(bytes calldata _l2Block) internal view {
    uint256 chainId;
    uint256 version;
    uint256 ts;
    // block number already constrained by start state hash
    assembly {
      chainId := calldataload(_l2Block.offset)
      version := calldataload(add(_l2Block.offset, 0x20))
      ts := calldataload(add(_l2Block.offset, 0x60))
    }

    if (block.chainid != chainId) {
      revert Errors.Rollup__InvalidChainId(chainId, block.chainid);
    }

    if (version != VERSION) {
      revert Errors.Rollup__InvalidVersion(version, VERSION);
    }

    if (ts > block.timestamp) {
      revert Errors.Rollup__TimestampInFuture();
    }

    // @todo @LHerskind consider if this is too strict
    // This will make multiple l2 blocks in the same l1 block impractical.
    // e.g., the first block will update timestamp which will make the second fail.
    // Could possibly allow multiple blocks if in same l1 block
    if (ts < lastBlockTs) {
      revert Errors.Rollup__TimestampTooOld();
    }
  }
}
