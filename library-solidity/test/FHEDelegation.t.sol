// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "encrypted-types/EncryptedTypes.sol";
import {FHE} from "../lib/FHE.sol";
import {CoprocessorConfig} from "../lib/Impl.sol";
import {HostContractsDeployerTestUtils} from "@fhevm-foundry/HostContractsDeployerTestUtils.sol";
import {ACL} from "@fhevm-host-contracts/contracts/ACL.sol";
import {aclAdd, fhevmExecutorAdd, kmsVerifierAdd} from "@fhevm-host-contracts/addresses/FHEVMHostAddresses.sol";
import {decryptionOracleAdd} from "@fhevm-host-contracts/addresses/DecryptionOracleAddress.sol";

contract DelegationLibraryAdapter {
    function setCoprocessorConfig(CoprocessorConfig memory config) external {
        FHE.setCoprocessor(config);
    }

    function delegateUserDecryption(address delegate, address contractAddress, uint64 expiryDate) external {
        FHE.delegateUserDecryption(delegate, contractAddress, expiryDate);
    }

    function delegateUnlimitedUserDecryption(address delegate, address contractAddress) external {
        FHE.delegateUnlimitedUserDecryption(delegate, contractAddress);
    }

    function delegateUserDecryptions(address delegate, address[] memory contractAddresses, uint64 expiryDate) external {
        FHE.delegateUserDecryptions(delegate, contractAddresses, expiryDate);
    }

    function delegateUnlimitedUserDecryptions(address delegate, address[] memory contractAddresses) external {
        FHE.delegateUnlimitedUserDecryptions(delegate, contractAddresses);
    }

    function revokeUserDecryptionDelegation(address delegate, address contractAddress) external {
        FHE.revokeUserDecryptionDelegation(delegate, contractAddress);
    }

    function revokeUserDecryptionDelegations(address delegate, address[] memory contractAddresses) external {
        FHE.revokeUserDecryptionDelegations(delegate, contractAddresses);
    }

    function allowHandle(bytes32 handle, address account) external {
        FHE.allow(euint256.wrap(handle), account);
    }

    function allowThisHandle(bytes32 handle) external {
        FHE.allowThis(euint256.wrap(handle));
    }

    function isUserDecryptable(bytes32 handle, address user, address contractAddress) external view returns (bool) {
        return FHE.isUserDecryptable(handle, user, contractAddress);
    }

    function isHandleDelegatedForUserDecryption(
        address delegator,
        address delegate,
        address contractAddress,
        bytes32 handle
    ) external view returns (bool) {
        return FHE.isHandleDelegatedForUserDecryption(delegator, delegate, contractAddress, handle);
    }

    function getDelegatedUserDecryptionExpiryDate(address delegate, address contractAddress)
        external
        view
        returns (uint64)
    {
        return FHE.getDelegatedUserDecryptionExpiryDate(delegate, contractAddress);
    }

    function getDelegatedUserDecryptionExpiryDateAsSelf(address delegate, address contractAddress)
        external
        view
        returns (uint64)
    {
        return this._getDelegatedUserDecryptionExpiryDateAsSelf(delegate, contractAddress);
    }

    function _getDelegatedUserDecryptionExpiryDateAsSelf(address delegate, address contractAddress)
        external
        view
        returns (uint64)
    {
        return FHE.getDelegatedUserDecryptionExpiryDate(delegate, contractAddress);
    }
}

contract FHEDelegationTest is HostContractsDeployerTestUtils {
    DelegationLibraryAdapter internal adapter;
    ACL internal acl;

    address internal constant OWNER = address(0xAA11);
    address internal constant PAUSER = address(0xBB22);
    address internal constant GATEWAY_SOURCE = address(0xCC33);
    uint64 internal constant GATEWAY_CHAIN_ID = 31337;
    address internal constant DELEGATE = address(0xDD44);
    address internal constant CONTRACT_CONTEXT = address(0xEE55);
    address internal constant UNAUTHORIZED_USER = address(0xCCFE);
    bytes32 internal constant HANDLE = bytes32(uint256(0x1234));

    function setUp() public {
        vm.warp(1_000_000);

        adapter = new DelegationLibraryAdapter();

        address[] memory kmsSigners = new address[](1);
        kmsSigners[0] = address(0x1111);
        address[] memory inputSigners = new address[](1);
        inputSigners[0] = address(0x2222);

        _deployFullHostStack(
            OWNER,
            PAUSER,
            GATEWAY_SOURCE,
            GATEWAY_SOURCE,
            GATEWAY_CHAIN_ID,
            kmsSigners,
            1,
            inputSigners,
            1
        );

        acl = ACL(aclAdd);

        CoprocessorConfig memory config = CoprocessorConfig({
            ACLAddress: aclAdd,
            CoprocessorAddress: fhevmExecutorAdd,
            DecryptionOracleAddress: decryptionOracleAdd,
            KMSVerifierAddress: kmsVerifierAdd
        });

        adapter.setCoprocessorConfig(config);
    }

    function _allowHandleFor(address account) internal {
        address adapterAddress = address(adapter);

        if (!acl.persistAllowed(HANDLE, adapterAddress)) {
            vm.prank(fhevmExecutorAdd);
            acl.allowTransient(HANDLE, adapterAddress);

            adapter.allowThisHandle(HANDLE);

            vm.prank(fhevmExecutorAdd);
            acl.cleanTransientStorage();
        }

        adapter.allowHandle(HANDLE, account);
    }

    function _expectActiveDelegation(uint64 expectedExpiry) internal view {
        uint64 stored = acl.getUserDecryptionDelegationExpirationDate(
            address(adapter),
            DELEGATE,
            CONTRACT_CONTEXT
        );
        assertEq(stored, expectedExpiry, "delegation expiry mismatch");
    }

    function test_IsUserDecryptable_ReturnsFalseWhenUserEqualsContract() public {
        _allowHandleFor(CONTRACT_CONTEXT);

        bool allowed = adapter.isUserDecryptable(HANDLE, CONTRACT_CONTEXT, CONTRACT_CONTEXT);
        assertFalse(allowed, "user == contract should not be decryptable");
    }

    function test_IsUserDecryptable_ReturnsFalseWhenUserNotPersistAllowed() public {
        _allowHandleFor(CONTRACT_CONTEXT);

        bool allowed = adapter.isUserDecryptable(HANDLE, UNAUTHORIZED_USER, CONTRACT_CONTEXT);
        assertFalse(allowed, "missing user allowance should return false");
    }

    function test_IsUserDecryptable_ReturnsFalseWhenContractNotPersistAllowed() public {
        _allowHandleFor(address(adapter));

        bool allowed = adapter.isUserDecryptable(HANDLE, address(adapter), CONTRACT_CONTEXT);
        assertFalse(allowed, "missing contract allowance should return false");
    }

    function test_IsUserDecryptable_ReturnsTrueWhenBothPersistAllowed() public {
        _allowHandleFor(address(adapter));
        _allowHandleFor(CONTRACT_CONTEXT);

        bool allowed = adapter.isUserDecryptable(HANDLE, address(adapter), CONTRACT_CONTEXT);
        assertTrue(allowed, "expected user decryptable context");
    }

    function test_IsHandleDelegatedForUserDecryption_ReturnsTrueWhenActive() public {
        _allowHandleFor(address(adapter));
        _allowHandleFor(CONTRACT_CONTEXT);

        uint64 expiryDate = uint64(block.timestamp + 2 hours);
        adapter.delegateUserDecryption(DELEGATE, CONTRACT_CONTEXT, expiryDate);

        bool delegated = adapter.isHandleDelegatedForUserDecryption(
            address(adapter),
            DELEGATE,
            CONTRACT_CONTEXT,
            HANDLE
        );
        assertTrue(delegated, "delegated handle should be active");
    }

    function test_IsHandleDelegatedForUserDecryption_ReturnsFalseWhenExpired() public {
        _allowHandleFor(address(adapter));
        _allowHandleFor(CONTRACT_CONTEXT);

        uint64 expiryDate = uint64(block.timestamp + 2 hours);
        adapter.delegateUserDecryption(DELEGATE, CONTRACT_CONTEXT, expiryDate);

        vm.warp(uint256(expiryDate) + 1);

        bool delegated = adapter.isHandleDelegatedForUserDecryption(
            address(adapter),
            DELEGATE,
            CONTRACT_CONTEXT,
            HANDLE
        );
        assertFalse(delegated, "delegation past expiry should be inactive");
    }

    function test_DelegateUserDecryption_PersistsExpiryInACL() public {
        uint64 expiryDate = uint64(block.timestamp + 3 hours);
        adapter.delegateUserDecryption(DELEGATE, CONTRACT_CONTEXT, expiryDate);

        _expectActiveDelegation(expiryDate);
    }

    function test_DelegateUnlimitedUserDecryption_SetsMaxExpiry() public {
        adapter.delegateUnlimitedUserDecryption(DELEGATE, CONTRACT_CONTEXT);

        _expectActiveDelegation(type(uint64).max);
    }

    function test_DelegateUserDecryptions_BatchAssignsEachContext() public {
        address[] memory contracts = new address[](2);
        contracts[0] = CONTRACT_CONTEXT;
        contracts[1] = address(0x7777);
        uint64 expiryDate = uint64(block.timestamp + 5 hours);

        adapter.delegateUserDecryptions(DELEGATE, contracts, expiryDate);

        uint64 first = acl.getUserDecryptionDelegationExpirationDate(address(adapter), DELEGATE, contracts[0]);
        uint64 second = acl.getUserDecryptionDelegationExpirationDate(address(adapter), DELEGATE, contracts[1]);
        assertEq(first, expiryDate, "first contract expiry mismatch");
        assertEq(second, expiryDate, "second contract expiry mismatch");
    }

    function test_DelegateUnlimitedUserDecryptions_BatchUsesMaxExpiry() public {
        address[] memory contracts = new address[](2);
        contracts[0] = CONTRACT_CONTEXT;
        contracts[1] = address(0x8888);

        adapter.delegateUnlimitedUserDecryptions(DELEGATE, contracts);

        uint64 first = acl.getUserDecryptionDelegationExpirationDate(address(adapter), DELEGATE, contracts[0]);
        uint64 second = acl.getUserDecryptionDelegationExpirationDate(address(adapter), DELEGATE, contracts[1]);
        assertEq(first, type(uint64).max, "first contract max expiry mismatch");
        assertEq(second, type(uint64).max, "second contract max expiry mismatch");
    }

    function test_RevokeUserDecryptionDelegation_ResetsExpiry() public {
        uint64 expiryDate = uint64(block.timestamp + 4 hours);
        adapter.delegateUserDecryption(DELEGATE, CONTRACT_CONTEXT, expiryDate);

        vm.roll(block.number + 1);

        adapter.revokeUserDecryptionDelegation(DELEGATE, CONTRACT_CONTEXT);

        uint64 stored = acl.getUserDecryptionDelegationExpirationDate(address(adapter), DELEGATE, CONTRACT_CONTEXT);
        assertEq(stored, 0, "revocation should clear expiry");
    }

    function test_RevokeUserDecryptionDelegations_BatchClearsEach() public {
        address[] memory contracts = new address[](2);
        contracts[0] = CONTRACT_CONTEXT;
        contracts[1] = address(0x9999);

        uint64 expiryDate = uint64(block.timestamp + 6 hours);
        adapter.delegateUserDecryptions(DELEGATE, contracts, expiryDate);

        vm.roll(block.number + 1);

        adapter.revokeUserDecryptionDelegations(DELEGATE, contracts);

        uint64 first = acl.getUserDecryptionDelegationExpirationDate(address(adapter), DELEGATE, contracts[0]);
        uint64 second = acl.getUserDecryptionDelegationExpirationDate(address(adapter), DELEGATE, contracts[1]);
        assertEq(first, 0, "first contract should be cleared");
        assertEq(second, 0, "second contract should be cleared");
    }

    function test_GetDelegatedUserDecryptionExpiryDate_ReturnsStoredValue() public {
        uint64 expiryDate = uint64(block.timestamp + 7 hours);
        adapter.delegateUserDecryption(DELEGATE, CONTRACT_CONTEXT, expiryDate);

        uint64 fetched = adapter.getDelegatedUserDecryptionExpiryDateAsSelf(DELEGATE, CONTRACT_CONTEXT);
        assertEq(fetched, expiryDate, "library expiry getter mismatch");
    }
}
