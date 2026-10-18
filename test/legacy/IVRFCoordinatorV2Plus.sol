// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title VRFV2PlusClient
/// @notice Minimal re-implementation of the Chainlink VRF v2.5 request encoding so that IMDPot does not
///         need the full Chainlink package. Mirrors the upstream VRFV2PlusClient library (chainlink v0.8 vrf dev).
library VRFV2PlusClient {
    /// @dev Tag prepended to the extra arguments, `bytes4(keccak256("VRF ExtraArgsV1"))`.
    bytes4 internal constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    /// @notice Extra arguments v1: whether the request is paid in native ETH (true) or LINK (false).
    struct ExtraArgsV1 {
        bool nativePayment;
    }

    /// @notice A randomness request as consumed by `IVRFCoordinatorV2Plus.requestRandomWords`.
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    /// @notice ABI-encodes the extra arguments with the v1 tag.
    function argsToBytes(ExtraArgsV1 memory extraArgs) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, extraArgs);
    }
}

/// @title IVRFCoordinatorV2Plus
/// @notice The subset of the Chainlink VRF v2.5 coordinator interface used by IMDPot.
interface IVRFCoordinatorV2Plus {
    /// @notice Requests a set of random words. The coordinator calls back `rawFulfillRandomWords` on the consumer.
    /// @param req The request parameters.
    /// @return requestId The identifier the fulfillment will carry.
    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req) external returns (uint256 requestId);
}

/// @title IVRFConsumerV2Plus
/// @notice The callback a VRF v2.5 coordinator invokes on a consumer.
interface IVRFConsumerV2Plus {
    /// @notice Entry point for the coordinator's fulfillment.
    /// @param requestId The identifier returned by `requestRandomWords`.
    /// @param randomWords The verified random words.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}
