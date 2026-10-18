// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVRFCoordinatorV2Plus, IVRFConsumerV2Plus, VRFV2PlusClient} from "../legacy/IVRFCoordinatorV2Plus.sol";

/// @notice Local stand-in for the Chainlink VRF v2.5 coordinator. It records requests and lets a test deliver any
///         random word. It demonstrates the contract's behaviour, not production randomness.
contract MockVRFCoordinator is IVRFCoordinatorV2Plus {
    struct Request {
        address consumer;
        bytes32 keyHash;
        uint256 subId;
        uint16 confirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
        bool fulfilled;
    }

    uint256 public nextRequestId = 1;
    bool public shouldRevert;
    mapping(uint256 => Request) public requests;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req) external returns (uint256 requestId) {
        require(!shouldRevert, "coordinator: subscription not funded");
        requestId = nextRequestId++;
        requests[requestId] = Request({
            consumer: msg.sender,
            keyHash: req.keyHash,
            subId: req.subId,
            confirmations: req.requestConfirmations,
            callbackGasLimit: req.callbackGasLimit,
            numWords: req.numWords,
            extraArgs: req.extraArgs,
            fulfilled: false
        });
    }

    /// @notice Delivers `word` for `requestId` to the consumer that made the request.
    function fulfill(uint256 requestId, uint256 word) external {
        Request storage req = requests[requestId];
        require(req.consumer != address(0), "unknown request");
        req.fulfilled = true;
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IVRFConsumerV2Plus(req.consumer).rawFulfillRandomWords(requestId, words);
    }

    /// @notice Delivers `word` with a bounded gas stipend, as the real coordinator does.
    function fulfillWithGas(uint256 requestId, uint256 word, uint256 gas) external returns (bool ok) {
        Request storage req = requests[requestId];
        require(req.consumer != address(0), "unknown request");
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        (ok,) = req.consumer.call{gas: gas}(
            abi.encodeWithSelector(IVRFConsumerV2Plus.rawFulfillRandomWords.selector, requestId, words)
        );
        req.fulfilled = ok;
    }

    /// @notice Delivers an arbitrary payload to `consumer` from this coordinator (used to test empty word arrays).
    function fulfillRaw(address consumer, uint256 requestId, uint256[] calldata words) external {
        IVRFConsumerV2Plus(consumer).rawFulfillRandomWords(requestId, words);
    }
}
