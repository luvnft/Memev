// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IMessageLibManager, SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

import "./BaseScript.s.sol";
import { Memecoin } from "../src/token/Memecoin.sol";
import { IOutrunDeployer } from "./IOutrunDeployer.sol";
import { MemeLiquidProof } from "../src/token/MemeLiquidProof.sol";
import { YieldDispatcher } from "../src/yield/YieldDispatcher.sol";
import { MemeverseLauncher } from "../src/verse/MemeverseLauncher.sol";
import { MemecoinYieldVault } from "../src/yield/MemecoinYieldVault.sol";
import { MemecoinDeployer } from "../src/token/deployer/MemecoinDeployer.sol";
import { MemecoinDaoGovernor } from "../src/governance/MemecoinDaoGovernor.sol";
import { IMemeverseRegistrar } from "../src/verse/interfaces/IMemeverseRegistrar.sol";
import { MemeverseRegistrarAtLocal } from "../src/verse/MemeverseRegistrarAtLocal.sol";
import { MemeverseRegistrationCenter } from "../src/verse/MemeverseRegistrationCenter.sol";
import { MemeverseRegistrarOmnichain } from "../src/verse/MemeverseRegistrarOmnichain.sol";
import { IMemeverseRegistrationCenter } from "../src/verse/interfaces/IMemeverseRegistrationCenter.sol";

contract MemeverseScript is BaseScript {
    using OptionsBuilder for bytes;

    uint256 public constant DAY = 24 * 3600;

    address internal UETH;
    address internal OUTRUN_DEPLOYER;
    address internal MEMECOIN_DEPLOYER;
    address internal MEMEVERSE_REGISTRAR;
    address internal MEMEVERSE_REGISTRATION_CENTER;
    address internal MEMECOIN_IMPLEMENTATION;
    address internal POL_IMPLEMENTATION;
    address internal MEMECOIN_VAULT_IMPLEMENTATION;
    address internal MEMECOIN_GOVERNOR_IMPLEMENTATION;
    address internal UETH_YIELD_DISPATCHER;
    address internal UETH_MEMEVERSE_LAUNCHER;
    
    address internal owner;
    address internal signer;
    address internal factory;
    address internal router;

    uint32[] public omnichainIds;
    mapping(uint32 chainId => address) public endpoints;
    mapping(uint32 chainId => uint32) public endpointIds;

    function run() public broadcaster {
        UETH = vm.envAddress("UETH");
        owner = vm.envAddress("OWNER");
        signer = vm.envAddress("SIGNER");
        factory = vm.envAddress("OUTRUN_AMM_FACTORY");
        router = vm.envAddress("OUTRUN_AMM_ROUTER");
        OUTRUN_DEPLOYER = vm.envAddress("OUTRUN_DEPLOYER");
        MEMECOIN_DEPLOYER = vm.envAddress("MEMECOIN_DEPLOYER");
        MEMEVERSE_REGISTRAR = vm.envAddress("MEMEVERSE_REGISTRAR");
        MEMEVERSE_REGISTRATION_CENTER = vm.envAddress("MEMEVERSE_REGISTRATION_CENTER");
        MEMECOIN_IMPLEMENTATION = vm.envAddress("MEMECOIN_IMPLEMENTATION");
        POL_IMPLEMENTATION = vm.envAddress("POL_IMPLEMENTATION");
        MEMECOIN_VAULT_IMPLEMENTATION = vm.envAddress("MEMECOIN_VAULT_IMPLEMENTATION");
        MEMECOIN_GOVERNOR_IMPLEMENTATION = vm.envAddress("MEMECOIN_GOVERNOR_IMPLEMENTATION");
        UETH_YIELD_DISPATCHER = vm.envAddress("UETH_YIELD_DISPATCHER_");
        UETH_MEMEVERSE_LAUNCHER = vm.envAddress("UETH_MEMEVERSE_LAUNCHER");

        // OutrunTODO Testnet id
        omnichainIds = [97, 84532, 421614, 43113, 80002, 57054, 168587773, 534351, 10143];
        _chainsInit();

        // _getDeployedImplementation(0);

        // _getDeployedRegistrationCenter(1);

        // _getDeployedMemecoinDeployer(1);
        // _getDeployedMemeverseRegistrar(1);

        // _getDeployedUETHMemeverseLauncher(1);
        // _getDeployedUETHYieldDispatcher(1);


        // _deployImplementation(0);

        // _deployRegistrationCenter(1);

        _deployMemecoinDeployer(1);
        _deployMemeverseRegistrar(1);

        _deployUETHMemeverseLauncher(1);
        _deployUETHYieldDispatcher(1);
    }

    function _chainsInit() internal {
        endpoints[97] = vm.envAddress("BSC_TESTNET_ENDPOINT");
        endpoints[84532] = vm.envAddress("BASE_SEPOLIA_ENDPOINT");
        endpoints[421614] = vm.envAddress("ARBITRUM_SEPOLIA_ENDPOINT");
        endpoints[43113] = vm.envAddress("AVALANCHE_FUJI_ENDPOINT");
        endpoints[80002] = vm.envAddress("POLYGON_AMOY_ENDPOINT");
        endpoints[57054] = vm.envAddress("SONIC_BLAZE_ENDPOINT");
        endpoints[11155420] = vm.envAddress("OPTIMISTIC_SEPOLIA_ENDPOINT");
        endpoints[300] = vm.envAddress("ZKSYNC_SEPOLIA_ENDPOINT");
        endpoints[59141] = vm.envAddress("LINEA_SEPOLIA_ENDPOINT");
        endpoints[168587773] = vm.envAddress("BLAST_SEPOLIA_ENDPOINT");
        endpoints[534351] = vm.envAddress("SCROLL_SEPOLIA_ENDPOINT");
        endpoints[10143] = vm.envAddress("MONAD_TESTNET_ENDPOINT");
        
        endpointIds[97] = uint32(vm.envUint("BSC_TESTNET_EID"));
        endpointIds[84532] = uint32(vm.envUint("BASE_SEPOLIA_EID"));
        endpointIds[421614] = uint32(vm.envUint("ARBITRUM_SEPOLIA_EID"));
        endpointIds[43113] = uint32(vm.envUint("AVALANCHE_FUJI_EID"));
        endpointIds[80002] = uint32(vm.envUint("POLYGON_AMOY_EID"));
        endpointIds[57054] = uint32(vm.envUint("SONIC_BLAZE_EID"));
        endpointIds[11155420] = uint32(vm.envUint("OPTIMISTIC_SEPOLIA_EID"));
        endpointIds[300] = uint32(vm.envUint("ZKSYNC_SEPOLIA_EID"));
        endpointIds[59141] = uint32(vm.envUint("LINEA_SEPOLIA_EID"));
        endpointIds[168587773] = uint32(vm.envUint("BLAST_SEPOLIA_EID"));
        endpointIds[534351] = uint32(vm.envUint("SCROLL_SEPOLIA_EID"));
        endpointIds[10143] = uint32(vm.envUint("MONAD_TESTNET_EID"));
    }

    function _getDeployedImplementation(uint256 nonce) internal view {
        bytes32 memecoinSalt = keccak256(abi.encodePacked("MemecoinImplementation", nonce));
        bytes32 liquidProofSalt = keccak256(abi.encodePacked("LiquidProofImplementation", nonce));
        bytes32 memecoinYieldVaultSalt = keccak256(abi.encodePacked("MemecoinYieldVaultImplementation", nonce));
        bytes32 memecoinDaoGovernorSalt = keccak256(abi.encodePacked("MemecoinDaoGovernorImplementation", nonce));
        
        address deployedMemecoinImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinSalt);
        address deployedLiquidProofImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, liquidProofSalt);
        address deployedMemecoinYieldVaultImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinYieldVaultSalt);
        address deployedMemecoinDaoGovernorImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinDaoGovernorSalt);

        console.log("MemecoinImplementation deployed on %s", deployedMemecoinImplementation);
        console.log("LiquidProofImplementation deployed on %s", deployedLiquidProofImplementation);
        console.log("MemecoinYieldVaultImplementation deployed on %s", deployedMemecoinYieldVaultImplementation);
        console.log("MemecoinDaoGovernorImplementation deployed on %s", deployedMemecoinDaoGovernorImplementation);
    }

    function _getDeployedMemecoinDeployer(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemecoinDeployer", nonce));
        address memecoinDeployer = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemecoinDeployer deployed on %s", memecoinDeployer);
    }

    function _getDeployedMemeverseRegistrar(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrar", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseRegistrar deployed on %s", deployed);
    }

    function _getDeployedRegistrationCenter(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrationCenter", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseRegistrationCenter deployed on %s", deployed);
    }

    function _getDeployedUETHMemeverseLauncher(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", "UETH", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("UETHMemeverseLauncher deployed on %s", deployed);
    }

    function _getDeployedUETHYieldDispatcher(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", "UETH", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("UETHYieldDispatcher deployed on %s", deployed);
    }


    /** DEPLOY **/

    function _deployImplementation(uint256 nonce) internal {
        bytes32 memecoinSalt = keccak256(abi.encodePacked("MemecoinImplementation", nonce));
        bytes32 liquidProofSalt = keccak256(abi.encodePacked("LiquidProofImplementation", nonce));
        bytes32 memecoinYieldVaultSalt = keccak256(abi.encodePacked("MemecoinYieldVaultImplementation", nonce));
        bytes32 memecoinDaoGovernorSalt = keccak256(abi.encodePacked("MemecoinDaoGovernorImplementation", nonce));
        
        address memecoinImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinSalt, type(Memecoin).creationCode);
        address liquidProofImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(liquidProofSalt, type(MemeLiquidProof).creationCode);
        address memecoinYieldVaultImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinYieldVaultSalt, type(MemecoinYieldVault).creationCode);
        address memecoinDaoGovernorImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinDaoGovernorSalt, type(MemecoinDaoGovernor).creationCode);
        
        console.log("MemecoinImplementation deployed on %s", memecoinImplementation);
        console.log("LiquidProofImplementation deployed on %s", liquidProofImplementation);
        console.log("MemecoinYieldVaultImplementation deployed on %s", memecoinYieldVaultImplementation);
        console.log("MemecoinDaoGovernorImplementation deployed on %s", memecoinDaoGovernorImplementation);
    }

    function _deployMemecoinDeployer(uint256 nonce) internal {
        address localEndpoint = endpoints[uint32(block.chainid)];

        bytes memory encodedArgs = abi.encode(
            owner,
            localEndpoint,
            MEMEVERSE_REGISTRAR,
            MEMECOIN_IMPLEMENTATION
        );

        bytes memory creationCode = abi.encodePacked(
            type(MemecoinDeployer).creationCode,
            encodedArgs
        );
        bytes32 salt = keccak256(abi.encodePacked("MemecoinDeployer", nonce));
        address memecoinDeployer = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("MemecoinDeployer deployed on %s", memecoinDeployer);
    }

    function _deployRegistrationCenter(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrationCenter", nonce));
        address localEndpoint = vm.envAddress("MONAD_TESTNET_ENDPOINT");
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseRegistrationCenter).creationCode,
            abi.encode(
                owner,
                localEndpoint,
                MEMEVERSE_REGISTRAR
            )
        );
        address centerAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        uint256 chainCount = omnichainIds.length;
        IMemeverseRegistrationCenter.LzEndpointIdPair[] memory endpointIdPairs = new IMemeverseRegistrationCenter.LzEndpointIdPair[](chainCount);
        for (uint32 i = 0; i < chainCount; i++) {
            uint32 chainId = omnichainIds[i];
            uint32 endpointId = endpointIds[chainId];
            endpointIdPairs[i] = IMemeverseRegistrationCenter.LzEndpointIdPair({ chainId: chainId, endpointId: endpointId});
            if (block.chainid == chainId || chainId == 57054 || chainId == 168587773 || chainId == 534351) continue;

            IOAppCore(centerAddr).setPeer(endpointId, bytes32(abi.encode(MEMEVERSE_REGISTRAR)));

            UlnConfig memory config = UlnConfig({
                confirmations: 1,
                requiredDVNCount: 0,
                optionalDVNCount: 0,
                optionalDVNThreshold: 0,
                requiredDVNs: new address[](0),
                optionalDVNs: new address[](0)
            });
            SetConfigParam[] memory params = new SetConfigParam[](1);
            params[0] = SetConfigParam({
                eid: endpointId,
                configType: 2,
                config: abi.encode(config)
            });
        
            address sendLib = IMessageLibManager(localEndpoint).getSendLibrary(centerAddr, endpointId);
            (address receiveLib, ) = IMessageLibManager(localEndpoint).getReceiveLibrary(centerAddr, endpointId);
            IMessageLibManager(localEndpoint).setConfig(centerAddr, sendLib, params);
            IMessageLibManager(localEndpoint).setConfig(centerAddr, receiveLib, params);
        }

        IMemeverseRegistrationCenter(centerAddr).setLzEndpointIds(endpointIdPairs);
        IMemeverseRegistrationCenter(centerAddr).setRegisterGasLimit(800000);
        IMemeverseRegistrationCenter(centerAddr).setDurationDaysRange(1, 3);
        IMemeverseRegistrationCenter(centerAddr).setLockupDaysRange(1, 365);

        console.log("MemeverseRegistrationCenter deployed on %s", centerAddr);
    }

    function _deployMemeverseRegistrar(uint256 nonce) internal {
        bytes memory encodedArgs;
        bytes memory creationBytecode;
        address localEndpoint = endpoints[uint32(block.chainid)];
        if (block.chainid == vm.envUint("MONAD_TESTNET_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                localEndpoint,
                MEMEVERSE_REGISTRATION_CENTER,
                MEMECOIN_DEPLOYER
            );
            creationBytecode = type(MemeverseRegistrarAtLocal).creationCode;
        } else {
            encodedArgs = abi.encode(
                owner,
                localEndpoint,
                MEMECOIN_DEPLOYER,
                uint32(vm.envUint("MONAD_TESTNET_EID")),
                uint32(vm.envUint("MONAD_TESTNET_CHAINID")),
                150000,
                500000,
                250000
            );
            creationBytecode = type(MemeverseRegistrarOmnichain).creationCode;
        }

        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrar", nonce));
        bytes memory creationCode = abi.encodePacked(
            creationBytecode,
            encodedArgs
        );
        address memeverseRegistrarAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);
        console.log("MemeverseRegistrar deployed on %s", memeverseRegistrarAddr);

        IMemeverseRegistrar.UPTLauncherPair[] memory pairs = new IMemeverseRegistrar.UPTLauncherPair[](1);
        pairs[0] = IMemeverseRegistrar.UPTLauncherPair({ upt: UETH, memeverseLauncher: UETH_MEMEVERSE_LAUNCHER});
        IMemeverseRegistrar(memeverseRegistrarAddr).setUPTLauncher(pairs);

        if (
            block.chainid != vm.envUint("MONAD_TESTNET_CHAINID") && 
            block.chainid != 57054 &&
            block.chainid != 168587773 &&
            block.chainid != 534351
        ) {
            uint32 centerEndpointId = uint32(vm.envUint("MONAD_TESTNET_EID"));
            IOAppCore(memeverseRegistrarAddr).setPeer(
                centerEndpointId, 
                bytes32(abi.encode(MEMEVERSE_REGISTRATION_CENTER))
            );
            
            UlnConfig memory config = UlnConfig({
                confirmations: 1,
                requiredDVNCount: 0,
                optionalDVNCount: 0,
                optionalDVNThreshold: 0,
                requiredDVNs: new address[](0),
                optionalDVNs: new address[](0)
            });
            SetConfigParam[] memory params = new SetConfigParam[](1);
            params[0] = SetConfigParam({
                eid: centerEndpointId,
                configType: 2,
                config: abi.encode(config)
            });

            console.log("ChainId is:", block.chainid);
            address sendLib = IMessageLibManager(localEndpoint).getSendLibrary(memeverseRegistrarAddr, centerEndpointId);
            (address receiveLib, ) = IMessageLibManager(localEndpoint).getReceiveLibrary(memeverseRegistrarAddr, centerEndpointId);
            IMessageLibManager(localEndpoint).setConfig(memeverseRegistrarAddr, sendLib, params);
            IMessageLibManager(localEndpoint).setConfig(memeverseRegistrarAddr, receiveLib, params);
        }

        uint256 chainCount = omnichainIds.length;
        IMemeverseRegistrar.LzEndpointIdPair[] memory endpointPairs = new IMemeverseRegistrar.LzEndpointIdPair[](chainCount);
        for (uint32 i = 0; i < chainCount; i++) {
            uint32 chainId = omnichainIds[i];
            uint32 endpointId = endpointIds[chainId];
            endpointPairs[i] = IMemeverseRegistrar.LzEndpointIdPair({ chainId: chainId, endpointId: endpointId});
        }
        IMemeverseRegistrar(memeverseRegistrarAddr).setLzEndpointIds(endpointPairs);
    }

    function _deployUETHMemeverseLauncher(uint256 nonce) internal {
        bytes memory encodedArgs = abi.encode(
            UETH,
            owner,
            factory,
            router,
            MEMEVERSE_REGISTRAR,
            POL_IMPLEMENTATION,
            MEMECOIN_VAULT_IMPLEMENTATION,
            MEMECOIN_GOVERNOR_IMPLEMENTATION,
            UETH_YIELD_DISPATCHER,
            1e19,
            1000000,
            10,
            115000,
            135000
        );
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseLauncher).creationCode,
            encodedArgs
        );
        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", "UETH", nonce));
        address UETHMemeverseLauncherAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("UETHMemeverseLauncher deployed on %s", UETHMemeverseLauncherAddr);
    }

    function _deployUETHYieldDispatcher(uint256 nonce) internal {
        address localEndpoint = endpoints[uint32(block.chainid)];

        bytes memory creationCode = abi.encodePacked(
            type(YieldDispatcher).creationCode,
            abi.encode(
                owner,
                localEndpoint,
                UETH_MEMEVERSE_LAUNCHER
            )
        );

        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", "UETH", nonce));
        address UETHYieldDispatcher = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("UETHYieldDispatcher deployed on %s", UETHYieldDispatcher);
    }
}
