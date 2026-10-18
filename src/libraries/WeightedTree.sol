// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title WeightedTree
/// @notice A storage Fenwick (binary indexed) tree over participant weights.
/// @dev Supports appending a participant, adding to an existing participant's weight, removing a
///      participant's whole weight, and locating the participant that owns a given cumulative weight
///      position. Every operation is O(log n), so winner selection stays gas-bounded regardless of how
///      many players join a round. All functions are internal so the library is inlined into the caller.
///      Indices are 1-based; index 0 is never used.
library WeightedTree {
    struct Tree {
        /// @dev Number of participants (leaves) appended so far.
        uint256 size;
        /// @dev Sum of all leaf weights currently in the tree.
        uint256 total;
        /// @dev Fenwick partial sums, 1-based.
        mapping(uint256 => uint256) nodes;
        /// @dev Current weight of each leaf, 1-based (kept so a leaf can be removed exactly).
        mapping(uint256 => uint256) weights;
    }

    error WeightedTreeIndexOutOfRange();
    error WeightedTreePositionOutOfRange();
    error WeightedTreeInsufficientWeight();

    /// @notice Appends a new leaf with weight `weight` and returns its 1-based index.
    function append(Tree storage tree, uint256 weight) internal returns (uint256 index) {
        index = tree.size + 1;
        tree.size = index;
        // The new node covers the range (index - lowbit(index), index]; all of it except the new leaf
        // already exists, so seed it with the prefix difference and then add the leaf.
        uint256 lowbit = index & (~index + 1);
        uint256 covered = prefixSum(tree, index - 1) - prefixSum(tree, index - lowbit);
        tree.nodes[index] = covered + weight;
        tree.weights[index] = weight;
        tree.total += weight;
    }

    /// @notice Adds `delta` weight to the leaf at `index`.
    function add(Tree storage tree, uint256 index, uint256 delta) internal {
        if (index == 0 || index > tree.size) revert WeightedTreeIndexOutOfRange();
        tree.weights[index] += delta;
        tree.total += delta;
        uint256 i = index;
        uint256 n = tree.size;
        while (i <= n) {
            tree.nodes[i] += delta;
            i += i & (~i + 1);
        }
    }

    /// @notice Subtracts `delta` weight from the leaf at `index` (used to take one drawn ticket out of the draw
    ///         while the player's remaining tickets keep their chances).
    function subtract(Tree storage tree, uint256 index, uint256 delta) internal {
        if (index == 0 || index > tree.size) revert WeightedTreeIndexOutOfRange();
        uint256 weight = tree.weights[index];
        if (delta > weight) revert WeightedTreeInsufficientWeight();
        if (delta == 0) return;
        tree.weights[index] = weight - delta;
        tree.total -= delta;
        uint256 i = index;
        uint256 n = tree.size;
        while (i <= n) {
            tree.nodes[i] -= delta;
            i += i & (~i + 1);
        }
    }

    /// @notice Removes the entire weight of the leaf at `index`.
    function remove(Tree storage tree, uint256 index) internal {
        if (index == 0 || index > tree.size) revert WeightedTreeIndexOutOfRange();
        subtract(tree, index, tree.weights[index]);
    }

    /// @notice Sum of weights of leaves 1..index.
    function prefixSum(Tree storage tree, uint256 index) internal view returns (uint256 sum) {
        uint256 i = index;
        while (i > 0) {
            sum += tree.nodes[i];
            i -= i & (~i + 1);
        }
    }

    /// @notice Returns the 1-based index of the leaf whose cumulative range contains `position`.
    /// @dev `position` is in [0, total). Leaf k owns positions [prefixSum(k-1), prefixSum(k)).
    ///      Leaves with zero weight own no positions and are never returned.
    function find(Tree storage tree, uint256 position) internal view returns (uint256 index) {
        if (position >= tree.total) revert WeightedTreePositionOutOfRange();
        uint256 n = tree.size;
        uint256 step = 1;
        while (step << 1 <= n) step <<= 1;
        uint256 remaining = position;
        uint256 pos = 0;
        while (step > 0) {
            uint256 next = pos + step;
            if (next <= n) {
                uint256 nodeValue = tree.nodes[next];
                if (remaining >= nodeValue) {
                    pos = next;
                    remaining -= nodeValue;
                }
            }
            step >>= 1;
        }
        index = pos + 1;
    }

    /// @notice Current weight of the leaf at `index`.
    function weightOf(Tree storage tree, uint256 index) internal view returns (uint256) {
        return tree.weights[index];
    }
}
