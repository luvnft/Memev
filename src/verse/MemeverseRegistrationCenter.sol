// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OApp, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { TokenHelper } from "../common/TokenHelper.sol";
import { IMemeverseRegistrar } from "../token/interfaces/IMemeverseRegistrar.sol";
import { IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrationCenter.sol";

/**
 * @title Memeverse Omnichain Registration Center (Deploy on BNB Chain)
 */
contract MemeverseRegistrationCenter is IMemeverseRegistrationCenter, OApp, TokenHelper {
    using OptionsBuilder for bytes;

    uint256 public constant DAY = 24 * 3600;
    uint128 public immutable OMNICHAIN_REGISTER_GAS_LIMIT;
    address public immutable LOCAL_MEMEVERSE_REGISTRAR;

    address public revenuePool;
    uint256 public registrationFee;
    uint128 public minDurationDays;
    uint128 public maxDurationDays;
    uint128 public minLockupDays;
    uint128 public maxLockupDays;

    // Main symbol mapping, recording the latest registration information
    mapping(string symbol => SymbolRegistration) public symbolRegistry;

    // Symbol history mapping, storing all valid registration records
    mapping(string symbol => mapping(uint256 uniqueId => SymbolRegistration)) public symbolHistory;

    mapping(uint256 uniqueId => mapping(string key => string)) public AdditionalInfo;

    mapping(uint32 chainId => uint32) endpointIds;

    constructor(
        address _owner, 
        address _revenuePool,
        address _lzEndpoint, 
        address _localMemeverseRegistrar, 
        uint256 _registrationFee, 
        uint128 _registerGasLimit
    ) OApp(_lzEndpoint, _owner) Ownable(_owner) {
        revenuePool = _revenuePool;
        registrationFee = _registrationFee;
        LOCAL_MEMEVERSE_REGISTRAR = _localMemeverseRegistrar;
        OMNICHAIN_REGISTER_GAS_LIMIT = _registerGasLimit;
    }

    /**
     * @dev Preview if the symbol can be registered
     */
    function previewRegistration(string calldata symbol) external view override returns (bool) {
        if (bytes(symbol).length >= 32) return false;
        SymbolRegistration storage currentRegistration = symbolRegistry[symbol];
        return block.timestamp > currentRegistration.unlockTime;
    }

    /**
     * @dev Registration memeverse
     */
    function registration(RegistrationParam memory param) public payable override {
        _registrationParamValidation(param);

        uint256 _registrationFee = registrationFee;
        require(msg.value >= _registrationFee, InsufficientRegistrationFee(_registrationFee));
        _transferOut(NATIVE, revenuePool, msg.value);

        uint256 currentTime = block.timestamp;
        SymbolRegistration storage currentRegistration = symbolRegistry[param.symbol];
        uint64 currentUnlockTime = currentRegistration.unlockTime;
        require(currentTime > currentUnlockTime, SymbolNotUnlock(currentUnlockTime));
        
        if (currentUnlockTime != 0) {
            symbolHistory[param.symbol][currentRegistration.uniqueId] = SymbolRegistration({
                uniqueId: currentRegistration.uniqueId,
                registrar: currentRegistration.registrar,
                unlockTime: currentUnlockTime
            });
        }
        
        uint64 unlockTime = uint64(currentTime + param.lockupDays * DAY);
        uint256 uniqueId = uint256(keccak256(abi.encodePacked(param.symbol, currentTime, msg.sender)));
        currentRegistration.uniqueId = uniqueId;
        currentRegistration.registrar = param.registrar;
        currentRegistration.unlockTime = unlockTime;

        // Set additionalInfo
        AdditionalInfo[uniqueId]["URI"] = param.uri;
        if(bytes(param.website).length > 0) AdditionalInfo[uniqueId]["WEBSITE"] = param.website;
        if(bytes(param.x).length > 0) AdditionalInfo[uniqueId]["X"] = param.x;
        if(bytes(param.telegram).length > 0) AdditionalInfo[uniqueId]["TELEGRAM"] = param.telegram;
        if(bytes(param.discord).length > 0) AdditionalInfo[uniqueId]["DISCORD"] = param.discord;
        if(bytes(param.description).length > 0) AdditionalInfo[uniqueId]["DESCRIPTION"] = param.description;

        IMemeverseRegistrar.MemeverseParam memory memeverseParam = IMemeverseRegistrar.MemeverseParam({
            name: param.name,
            symbol: param.symbol,
            uri: param.uri,
            uniqueId: uniqueId,
            maxFund: uint128(param.maxFund),
            endTime: uint64(currentTime + param.durationDays * DAY),
            unlockTime: unlockTime,
            omnichainIds: param.omnichainIds,
            creator: param.registrar
        });
        _omnichainSend(param.omnichainIds,  memeverseParam);

        emit Registration(uniqueId, param);
    }

    /**
     * @dev Cancel registration at local chain
     */
    function cancelRegistration(uint256 uniqueId, string calldata symbol) external override {
        require(msg.sender == LOCAL_MEMEVERSE_REGISTRAR, PermissionDenied());

        _cancelRegistration(uniqueId, symbol);
    }

    /**
     * @dev Calculate the fee quotation for cross-chain transactions
     */
    function quoteSend(
        uint32[] memory omnichainIds, 
        bytes memory options, 
        bytes memory message
    ) public view returns (uint256, uint256[] memory, uint32[] memory) {
        uint256 len = omnichainIds.length;
        uint256 totalFee;
        uint256[] memory fees = new uint256[](len);
        uint32[] memory eids = new uint32[](len);
        for (uint256 i = 0; i < len; i++) {
            if (omnichainIds[i] == block.chainid) {
                fees[i] = 0;
                eids[i] = 0;
            } else {
                uint32 eid = endpointIds[omnichainIds[i]];
                uint256 fee = _quote(eid, message, options, false).nativeFee;
                totalFee += fee;
                fees[i] = fee;
                eids[i] = eid;
            }
        }

        return (totalFee, fees, eids);
    }

    function _omnichainSend(uint32[] memory omnichainIds, IMemeverseRegistrar.MemeverseParam memory param) internal {
        bytes memory message = abi.encode(param);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(OMNICHAIN_REGISTER_GAS_LIMIT , 0);
        (uint256 totalFee, uint256[] memory fees, uint32[] memory eids) = quoteSend(omnichainIds, options, message);
        require(msg.value >= totalFee + registrationFee, InsufficientFee());

        uint256 remainingValue = msg.value;
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            if (omnichainIds[i] == block.chainid) {
                IMemeverseRegistrar(LOCAL_MEMEVERSE_REGISTRAR).registerAtLocal(param);
            } else {
                MessagingFee memory fee = _quote(eids[i], message, options, false);
                remainingValue -= fee.nativeFee;
                require(remainingValue >= registrationFee, InsufficientFee());

                _lzSend(eids[i], message, options, MessagingFee({nativeFee: fees[i], lzTokenFee: 0}), param.creator);
            }
        }
    }

    function _registrationParamValidation(RegistrationParam memory param) internal view {
        require(
            param.lockupDays >= minLockupDays && 
            param.lockupDays <= maxLockupDays && 
            param.durationDays >= minDurationDays && 
            param.durationDays <= maxDurationDays && 
            bytes(param.name).length > 0 && bytes(param.name).length < 32 && 
            bytes(param.symbol).length > 0 && bytes(param.symbol).length < 32 && 
            bytes(param.uri).length > 0 && 
            bytes(param.website).length < 32 && 
            bytes(param.x).length < 32 && 
            bytes(param.telegram).length < 32 && 
            bytes(param.discord).length < 32 && 
            bytes(param.description).length < 256 && 
            param.omnichainIds.length > 0 && 
            param.registrar != address(0), 
            InvalidRegisterInfo()
        );

        if (param.omnichainIds.length > 1) {
            require(param.maxFund > 0 && param.maxFund < type(uint128).max, MaxFundNotSet());
        }
    }

    /**
     * @dev Internal function to implement lzReceive logic(Cancel Registration)
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal virtual override {
        (uint256 uniqueId, RegistrationParam memory param) = abi.decode(_message, (uint256, RegistrationParam));
        if (uniqueId == 0) {
            registration(param);
        } else {
            _cancelRegistration(uniqueId, param.symbol);
        }
    }

    /**
     * @dev Cancel registration when Memeverse enters the refund stage on all chains.
     */
    function _cancelRegistration(uint256 uniqueId, string memory symbol) internal {
        SymbolRegistration storage currentRegistration = symbolRegistry[symbol];
        uint256 currentUniqueId = currentRegistration.uniqueId;
        require(currentUniqueId == uniqueId, UniqueIdMismatch(currentUniqueId));
        
        currentRegistration.uniqueId = 0;
        currentRegistration.registrar = address(0);
        currentRegistration.unlockTime = 0;

        emit CancelRegistration(uniqueId, symbol);
    }


    /*/////////////////////////////////////////////////////
                Memeverse Registration Config
    /////////////////////////////////////////////////////*/

    function setRegistrationFee(uint256 _registrationFee) external override onlyOwner {
        registrationFee = _registrationFee;
    }

    function setRevenuePool(address _revenuePool) external override onlyOwner {
        require(_revenuePool != address(0), ZeroInput());
        revenuePool = _revenuePool;
    }

    /**
     * @dev Set genesis stage duration days range
     * @param _minDurationDays - Min genesis stage duration days
     * @param _maxDurationDays - Max genesis stage duration days
     */
    function setDurationDaysRange(uint128 _minDurationDays, uint128 _maxDurationDays) external override onlyOwner {
        require(
            _minDurationDays != 0 && 
            _maxDurationDays != 0 && 
            _minDurationDays < _maxDurationDays, 
            ErrorInput()
        );

        minDurationDays = _minDurationDays;
        maxDurationDays = _maxDurationDays;
    }

    /**
     * @dev Set liquidity lockup days range
     * @param _minLockupDays - Min liquidity lockup days
     * @param _maxLockupDays - Max liquidity lockup days
     */
    function setLockupDaysRange(uint128 _minLockupDays, uint128 _maxLockupDays) external override onlyOwner {
        require(
            _minLockupDays != 0 && 
            _maxLockupDays != 0 && 
            _minLockupDays < _maxLockupDays, 
            ErrorInput()
        );

        minLockupDays = _minLockupDays;
        maxLockupDays = _maxLockupDays;
    }

    /*////////////////////////////////////////////////
                    Layerzero Config
    ////////////////////////////////////////////////*/

    function setPeer(uint32[] calldata _eids, bytes32[] calldata _peers) external override onlyOwner {
        require(_eids.length == _peers.length, LengthMismatch());

        for (uint256 i = 0; i < _eids.length; i++) {
            setPeer(_eids[i], _peers[i]);
        }
    }

    function setLzEndpointId(IMemeverseRegistrar.LzEndpointId[] calldata endpoints) external override onlyOwner {
        for (uint256 i = 0; i < endpoints.length; i++) {
            endpointIds[endpoints[i].chainId] = endpoints[i].endpointId;
        }
    }
}
