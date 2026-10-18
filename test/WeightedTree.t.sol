// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WeightedTree} from "../src/libraries/WeightedTree.sol";

contract WeightedTreeHarness {
    using WeightedTree for WeightedTree.Tree;

    WeightedTree.Tree internal tree;

    function append(uint256 w) external returns (uint256) {
        return tree.append(w);
    }

    function add(uint256 i, uint256 d) external {
        tree.add(i, d);
    }

    function remove(uint256 i) external {
        tree.remove(i);
    }

    function subtract(uint256 i, uint256 d) external {
        tree.subtract(i, d);
    }

    function find(uint256 p) external view returns (uint256) {
        return tree.find(p);
    }

    function prefixSum(uint256 i) external view returns (uint256) {
        return tree.prefixSum(i);
    }

    function total() external view returns (uint256) {
        return tree.total;
    }

    function size() external view returns (uint256) {
        return tree.size;
    }

    function weightOf(uint256 i) external view returns (uint256) {
        return tree.weightOf(i);
    }
}

/// @notice Unit and fuzz tests for the weighted selection tree.
contract WeightedTreeTest is Test {
    WeightedTreeHarness internal h;

    function setUp() public {
        h = new WeightedTreeHarness();
    }

    function test_appendFindAndRemove() public {
        assertEq(h.append(5), 1);
        assertEq(h.append(0), 2);
        assertEq(h.append(3), 3);
        assertEq(h.append(2), 4);
        assertEq(h.total(), 10);
        assertEq(h.prefixSum(1), 5);
        assertEq(h.prefixSum(2), 5);
        assertEq(h.prefixSum(3), 8);
        assertEq(h.prefixSum(4), 10);
        assertEq(h.find(0), 1);
        assertEq(h.find(4), 1);
        assertEq(h.find(5), 3); // zero-weight leaf 2 owns no positions
        assertEq(h.find(7), 3);
        assertEq(h.find(8), 4);
        assertEq(h.find(9), 4);
        vm.expectRevert(WeightedTree.WeightedTreePositionOutOfRange.selector);
        h.find(10);

        h.add(2, 4);
        assertEq(h.total(), 14);
        assertEq(h.find(5), 2);
        assertEq(h.find(8), 2);
        assertEq(h.find(9), 3);

        h.remove(1);
        assertEq(h.total(), 9);
        assertEq(h.weightOf(1), 0);
        assertEq(h.find(0), 2);
        assertEq(h.find(3), 2);
        assertEq(h.find(4), 3);
        assertEq(h.find(8), 4);
        h.remove(1); // idempotent
        assertEq(h.total(), 9);

        vm.expectRevert(WeightedTree.WeightedTreeIndexOutOfRange.selector);
        h.add(5, 1);
        vm.expectRevert(WeightedTree.WeightedTreeIndexOutOfRange.selector);
        h.add(0, 1);
        vm.expectRevert(WeightedTree.WeightedTreeIndexOutOfRange.selector);
        h.remove(7);
    }

    function test_subtractTakesPartOfALeaf() public {
        h.append(5); // leaf 1
        h.append(4); // leaf 2
        h.append(3); // leaf 3
        h.subtract(2, 1);
        assertEq(h.total(), 11);
        assertEq(h.weightOf(2), 3);
        assertEq(h.prefixSum(2), 8);
        assertEq(h.find(5), 2);
        assertEq(h.find(7), 2);
        assertEq(h.find(8), 3);
        h.subtract(2, 3);
        assertEq(h.weightOf(2), 0);
        assertEq(h.find(5), 3); // leaf 2 owns no positions once empty
        h.subtract(2, 0); // no-op
        assertEq(h.total(), 8);
        vm.expectRevert(WeightedTree.WeightedTreeInsufficientWeight.selector);
        h.subtract(2, 1);
        vm.expectRevert(WeightedTree.WeightedTreeInsufficientWeight.selector);
        h.subtract(1, 6);
        vm.expectRevert(WeightedTree.WeightedTreeIndexOutOfRange.selector);
        h.subtract(0, 1);
        vm.expectRevert(WeightedTree.WeightedTreeIndexOutOfRange.selector);
        h.subtract(4, 1);
    }

    function testFuzz_subtractMatchesPrefixSums(uint8[16] memory weights, uint8[8] memory cuts, uint256 pos) public {
        uint256 n = weights.length;
        uint256[] memory w = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            w[i] = weights[i];
            h.append(w[i]);
        }
        for (uint256 i; i < cuts.length; ++i) {
            uint256 idx = (uint256(cuts[i]) % n) + 1;
            uint256 delta = w[idx - 1] == 0 ? 0 : uint256(cuts[i]) % (w[idx - 1] + 1);
            h.subtract(idx, delta);
            w[idx - 1] -= delta;
        }
        uint256 total;
        for (uint256 i; i < n; ++i) {
            total += w[i];
            assertEq(h.weightOf(i + 1), w[i]);
        }
        assertEq(h.total(), total);
        if (total == 0) return;
        pos = pos % total;
        uint256 found = h.find(pos);
        uint256 before;
        for (uint256 i; i + 1 < found; ++i) {
            before += w[i];
        }
        assertGt(w[found - 1], 0, "zero-weight leaf chosen");
        assertLe(before, pos);
        assertLt(pos, before + w[found - 1]);
    }

    function testFuzz_findMatchesPrefixSums(uint8[16] memory weights, uint8[8] memory additions, uint256 pos) public {
        uint256 n = weights.length;
        uint256[] memory w = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            w[i] = weights[i];
            h.append(w[i]);
        }
        for (uint256 i; i < additions.length; ++i) {
            uint256 idx = (uint256(additions[i]) % n) + 1;
            h.add(idx, additions[i]);
            w[idx - 1] += additions[i];
        }
        // Remove a couple of leaves, as winner selection does.
        h.remove(1);
        w[0] = 0;
        h.remove(n / 2);
        w[n / 2 - 1] = 0;

        uint256 total;
        for (uint256 i; i < n; ++i) {
            total += w[i];
        }
        assertEq(h.total(), total);
        if (total == 0) return;
        pos = pos % total;
        uint256 found = h.find(pos);
        uint256 before;
        for (uint256 i; i + 1 < found; ++i) {
            before += w[i];
        }
        assertGt(w[found - 1], 0, "zero-weight leaf chosen");
        assertLe(before, pos);
        assertLt(pos, before + w[found - 1]);
    }
}
