// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Cryft Labs
pragma solidity 0.8.37;

/// @title Kota proxy deployment shim — OpenZeppelin Transparent pattern
/// @notice Requires `npm i @openzeppelin/contracts`. Re-exports OZ's
///         TransparentUpgradeableProxy + ProxyAdmin so deployment tooling
///         (thirdweb/foundry) compiles them from this repo.
///
/// Deployment steps:
///   1. Deploy KotaAccessSBT() implementation. Its constructor disables all
///      initializers and creates no functional state.
///   2. Deploy KotaAccessFactory() implementation. Its constructor also
///      disables all initializers and creates no functional state.
///   3. Deploy TransparentUpgradeableProxy(
///        sbtImpl,
///        <proxyAdminOwner>,                      // OZ v5 deploys ProxyAdmin for you
///        abi.encodeCall(KotaAccessSBT.initialize,
///          ("Kota Access Token", "KAT", initialAdmin)))
///      -> one tx: initialAdmin becomes issuer AND receives the minted
///         admin NFT (ROLE_ADMIN, token #1).
///   4. Deploy TransparentUpgradeableProxy(
///        factoryImpl, <proxyAdminOwner>,
///        abi.encodeCall(
///            KotaAccessFactory.initialize,
///            (initialAdmin, adminAccessProxy)
///        ))
///   5. On the access proxy, create plan tiers; grant ROLE_SYSTEM (3) only to
///      approved platform service/multisig wallets; grant ROLE_TENANT (1) and
///      assign a tier to each tenant operator.
///   6. Use the PROXY addresses everywhere (router gates, registryFor). Never
///      embed a ROLE_SYSTEM private key in a frontend.
///
/// Fresh chain 113211 (audit X-69): the factory sits behind Contracts/Paladin's ManagedApplicationProxy with a
/// ManagedProxyAdmin (Ownable2Step, renounce disabled) instead of this one-step OZ5 ProxyAdmin; see
/// Tools/TenantRegistry/build.py for the pinned inputs and the deploy order.
///
/// Upgrades: ProxyAdmin.upgradeAndCall(proxy, newImpl, "") — only the
/// ProxyAdmin owner can upgrade; implementations contain no upgrade logic.
/// Storage discipline still applies: append-only layout in new versions.

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
