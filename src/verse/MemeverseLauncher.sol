// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import { IBurnable } from "../common/IBurnable.sol";
import { IMemecoin } from "../token/interfaces/IMemecoin.sol";
import { IOutrunAMMPair } from "../common/IOutrunAMMPair.sol";
import { TokenHelper, IERC20 } from "../common/TokenHelper.sol";
import { IOutrunAMMRouter } from "../common/IOutrunAMMRouter.sol";
import { OutrunAMMLibrary } from "../libraries/OutrunAMMLibrary.sol";
import { IMemeverseLauncher } from "./interfaces/IMemeverseLauncher.sol";
import { IMemeLiquidProof } from "../token/interfaces/IMemeLiquidProof.sol";
import { IMemecoinDaoGovernor } from "../governance/interfaces/IMemecoinDaoGovernor.sol";
import { MemecoinYieldVault, IMemecoinYieldVault } from "../yield/MemecoinYieldVault.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title Trapping into the memeverse
 */
contract MemeverseLauncher is IMemeverseLauncher, TokenHelper, Pausable, Ownable {
    using Clones for address;
    using OptionsBuilder for bytes;

    uint256 public constant RATIO = 10000;
    uint256 public constant SWAP_FEERATE = 100;
    address public immutable UPT;
    address public immutable OUTRUN_AMM_ROUTER;
    address public immutable OUTRUN_AMM_FACTORY;
    address public immutable LOCAL_LZ_ENDPOINT;

    address public memeverseRegistrar;
    address public memecoinImplementation;
    address public polImplementation;
    address public vaultImplementation;
    address public governorImplementation;
    address public yieldDispatcher;
    
    uint256 public minTotalFunds;
    uint256 public fundBasedAmount;
    uint256 public autoBotFeeRate;
    uint128 public oftReceiveGasLimit;
    uint128 public yieldDispatcherGasLimit;

    mapping(uint32 chainId => uint32) public lzEndpointIds;
    mapping(address memecoin => uint256) public memecoinToIds;
    mapping(uint256 verseId => Memeverse) public memeverses;
    mapping(uint256 verseId => uint256) public claimableLiquidProofs;
    mapping(uint256 verseId => GenesisFund) public genesisFunds;
    mapping(uint256 verseId => mapping(address account => uint256)) public userTotalFunds;

    constructor(
        address _UPT,
        address _owner,
        address _outrunAMMFactory,
        address _outrunAMMRouter,
        address _localLzEndpoint,
        address _memeverseRegistrar,
        address _memecoinImplementation,
        address _polImplementation,
        address _vaultImplementation,
        address _governorImplementation,
        address _yieldDispatcher,
        uint256 _minTotalFunds,
        uint256 _fundBasedAmount,
        uint256 _autoBotFeeRate,
        uint128 _oftReceiveGasLimit,
        uint128 _yieldDispatcherGasLimit
    ) Ownable(_owner) {
        UPT = _UPT;
        OUTRUN_AMM_ROUTER = _outrunAMMRouter;
        OUTRUN_AMM_FACTORY = _outrunAMMFactory;
        LOCAL_LZ_ENDPOINT = _localLzEndpoint;
        memeverseRegistrar = _memeverseRegistrar;
        memecoinImplementation = _memecoinImplementation;
        polImplementation = _polImplementation;
        vaultImplementation = _vaultImplementation;
        governorImplementation = _governorImplementation;
        yieldDispatcher = _yieldDispatcher;
        minTotalFunds = _minTotalFunds;
        fundBasedAmount = _fundBasedAmount;
        autoBotFeeRate =_autoBotFeeRate;
        oftReceiveGasLimit = _oftReceiveGasLimit;
        yieldDispatcherGasLimit = _yieldDispatcherGasLimit;

        _safeApproveInf(_UPT, _outrunAMMRouter);
    }

    /**
     * @notice Get the verse id by memecoin.
     * @param memecoin -The address of the memecoin.
     * @return verseId The verse id.
     */
    function getVerseIdByMemecoin(address memecoin) external view override returns (uint256 verseId) {
        verseId = memecoinToIds[memecoin];
    }

    /**
     * @notice Get the memeverse by verse id.
     * @param verseId - The verse id.
     * @return verse - The memeverse.
     */
    function getMemeverseByVerseId(uint256 verseId) external view override returns (Memeverse memory verse) {
        verse = memeverses[verseId];
    }

    /**
     * @notice Get the memeverse by memecoin.
     * @param memecoin - The address of the memecoin.
     * @return verse - The memeverse.
     */
    function getMemeverseByMemecoin(address memecoin) external view override returns (Memeverse memory verse) {
        verse = memeverses[memecoinToIds[memecoin]];
    }

    /**
     * @notice Get the yield vault by verse id.
     * @param verseId - The verse id.
     * @return yieldVault - The yield vault.
     */
    function getYieldVaultByVerseId(uint256 verseId) external view override returns (address yieldVault) {
        yieldVault = memeverses[verseId].yieldVault;
    }

    /**
     * @notice Get the yield vault by memecoin.
     * @param memecoin - The address of the memecoin.
     * @return yieldVault - The yield vault.
     */
    function getYieldVaultByMemecoin(address memecoin) external view override returns (address yieldVault) {
        yieldVault = memeverses[memecoinToIds[memecoin]].yieldVault;
    }

    /**
     * @notice Get the governor by verse id.
     * @param verseId - The verse id.
     * @return governor - The governor.
     */
    function getGovernorByVerseId(uint256 verseId) external view override returns (address governor) {
        governor = memeverses[verseId].governor;
    }

    /**
     * @notice Get the governor by memecoin.
     * @param memecoin - The address of the memecoin.
     * @return governor - The governor.
     */
    function getGovernorByMemecoin(address memecoin) external view override returns (address governor) {
        governor = memeverses[memecoinToIds[memecoin]].governor;
    }

    /**
     * @dev Preview claimable liquidProof of user after Genesis Stage 
     * @param verseId - Memeverse id
     * @return claimableAmount - The claimable amount.
     */
    function claimableLiquidProof(uint256 verseId) public view override returns (uint256 claimableAmount) {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage >= Stage.Locked, NotReachedLockedStage(currentStage));

        uint256 totalFunds = genesisFunds[verseId].totalMemecoinFunds + genesisFunds[verseId].totalLiquidProofFunds;
        uint256 userFunds = userTotalFunds[verseId][msg.sender];
        uint256 totalUserLiquidProof = claimableLiquidProofs[verseId];
        claimableAmount = totalUserLiquidProof * userFunds / totalFunds;
    }

    /**
     * @dev Preview Genesis liquidity market maker fees for DAO Treasury (UPT) and Yield Vault(Memecoin)
     * @param verseId - Memeverse id
     * @return UPTFee - The UPT fee.
     * @return memecoinFee - The memecoin fee.
     */
    function previewGenesisMakerFees(uint256 verseId) public view override returns (uint256 UPTFee, uint256 memecoinFee) {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage >= Stage.Locked, NotReachedLockedStage(currentStage));

        address memecoin = verse.memecoin;
        IOutrunAMMPair memecoinPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, memecoin, UPT, SWAP_FEERATE));
        (uint256 amount0, uint256 amount1) = memecoinPair.previewMakerFee();
        address token0 = memecoinPair.token0();
        UPTFee = token0 == UPT ? amount0 : amount1;
        memecoinFee = token0 == memecoin ? amount0 : amount1;

        address liquidProof = verse.liquidProof;
        IOutrunAMMPair liquidProofPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, liquidProof, UPT, SWAP_FEERATE));
        (uint256 amount2, uint256 amount3) = liquidProofPair.previewMakerFee();
        address token2 = liquidProofPair.token0();
        UPTFee = token2 == UPT ? UPTFee + amount2 : UPTFee + amount3;
    }

    /**
     * @dev Quote the LZ fee for the redemption and distribution of fees
     * @param verseId - Memeverse id
     * @return lzFee - The LZ fee.
     * @notice The LZ fee is only charged when the governance chain is not the same as the current chain,
     *         and msg.value needs to be greater than the quoted lzFee for the redeemAndDistributeFees transaction.
     */
    function quoteDistributionLzFee(uint256 verseId) external view returns (uint256 lzFee) {
        Memeverse storage verse = memeverses[verseId];
        uint32 govChainId = verse.omnichainIds[0];
        if (govChainId == block.chainid) return 0;
        
        (uint256 UPTFee, uint256 memecoinFee) = previewGenesisMakerFees(verseId);
        
        uint32 govEndpointId = lzEndpointIds[govChainId];
        bytes memory yieldDispatcherOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
            .addExecutorLzComposeOption(0, yieldDispatcherGasLimit, 0);
        if (UPTFee != 0) {
            SendParam memory sendUPTParam = SendParam({
                dstEid: govEndpointId,
                to: bytes32(uint256(uint160(yieldDispatcher))),
                amountLD: UPTFee,
                minAmountLD: 0,
                extraOptions: yieldDispatcherOptions,
                composeMsg: abi.encode(verseId, "UPT"),
                oftCmd: abi.encode()
            });
            MessagingFee memory govMessagingFee = IOFT(UPT).quoteSend(sendUPTParam, false);
            lzFee += govMessagingFee.nativeFee;
        }

        if (memecoinFee != 0) {
            SendParam memory sendMemecoinParam = SendParam({
                dstEid: govEndpointId,
                to: bytes32(uint256(uint160(yieldDispatcher))),
                amountLD: memecoinFee,
                minAmountLD: 0,
                extraOptions: yieldDispatcherOptions,
                composeMsg: abi.encode(verseId, "Memecoin"),
                oftCmd: abi.encode()
            });
            MessagingFee memory memecoinMessagingFee = IOFT(verse.memecoin).quoteSend(sendMemecoinParam, false);
            lzFee += memecoinMessagingFee.nativeFee;
        }
    }

    /**
     * @dev Genesis memeverse by depositing UPT
     * @param verseId - Memeverse id
     * @param amountInUPT - Amount of UPT
     * @param user - Address of user participating in the genesis
     * @notice Approve fund token first
     */
    function genesis(uint256 verseId, uint256 amountInUPT, address user) external whenNotPaused override {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage == Stage.Genesis, NotGenesisStage(currentStage));

        _transferIn(UPT, msg.sender, amountInUPT);

        uint256 increasedMemecoinFund;
        uint256 increasedLiquidProofFund;
        unchecked {
            increasedLiquidProofFund = amountInUPT / 3;
            increasedMemecoinFund = amountInUPT - increasedLiquidProofFund;
        }

        GenesisFund storage genesisFund = genesisFunds[verseId];
        unchecked {
            genesisFund.totalMemecoinFunds += uint128(increasedMemecoinFund);
            genesisFund.totalLiquidProofFunds += uint128(increasedLiquidProofFund);
            userTotalFunds[verseId][user] += amountInUPT;
        }

        emit Genesis(verseId, user, increasedMemecoinFund, increasedLiquidProofFund);
    }

    /**
     * @dev Adaptively change the Memeverse stage
     * @param verseId - Memeverse id
     * @return currentStage - The current stage.
     */
    function changeStage(uint256 verseId) external whenNotPaused override returns (Stage currentStage) {
        uint256 currentTime = block.timestamp;
        Memeverse storage verse = memeverses[verseId];
        uint256 endTime = verse.endTime;
        currentStage = verse.currentStage;
        require(endTime != 0 && currentTime > endTime && currentStage != Stage.Refund, InTheGenesisStage(endTime));

        GenesisFund storage genesisFund = genesisFunds[verseId];
        uint128 totalMemecoinFunds = genesisFund.totalMemecoinFunds;
        uint128 totalLiquidProofFunds = genesisFund.totalLiquidProofFunds;
        address yieldVault;
        if (currentStage == Stage.Genesis) {
            if (totalMemecoinFunds + totalLiquidProofFunds < minTotalFunds) {
                verse.currentStage = Stage.Refund;
                currentStage = Stage.Refund;
            } else {
                string memory name = verse.name;
                string memory symbol = verse.symbol;
                address creator = verse.creator;
                address memecoin = verse.memecoin;
                bytes32 salt = keccak256(abi.encodePacked(symbol, creator, verseId));

                // Deploy POL
                address liquidProof = polImplementation.cloneDeterministic(salt);
                IMemeLiquidProof(liquidProof).initialize(
                    string(abi.encodePacked("POL-", name)), 
                    string(abi.encodePacked("POL-", symbol)), 
                    18, 
                    memecoin, 
                    address(this)
                );
                verse.liquidProof = liquidProof;

                // Deploy Memecoin Yield Vault on Governance Chain
                address _vaultImplementation = vaultImplementation;
                uint32 govChainId = verse.omnichainIds[0];
                yieldVault = _vaultImplementation.predictDeterministicAddress(salt);
                if (govChainId == block.chainid) {
                    _vaultImplementation.cloneDeterministic(salt);
                    IMemecoinYieldVault(yieldVault).initialize(
                        string(abi.encodePacked("Staked ", name)),
                        string(abi.encodePacked("s", symbol)),
                        memecoin,
                        verseId
                    );
                }
                verse.yieldVault = yieldVault;

                // Deploy Memecoin DAO Governor on Governance Chain
                bytes memory initData = abi.encodeWithSelector(
                    IMemecoinDaoGovernor.initialize.selector,
                    string(abi.encodePacked(name, " DAO")),
                    IVotes(yieldVault),  // voting token
                    1 days,              // voting delay
                    1 weeks,             // voting period
                    10000e18,            // proposal threshold (10000 tokens)
                    30                   // quorum (30%)
                );
                bytes memory proxyBytecode = abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(governorImplementation, initData)
                );
                if (govChainId == block.chainid) {
                    verse.governor = Create2.deploy(0, salt, proxyBytecode);
                } else {
                    verse.governor = Create2.computeAddress(salt, keccak256(proxyBytecode));
                }

                // Deploy memecoin liquidity
                uint256 memecoinAmount = genesisFunds[verseId].totalMemecoinFunds * fundBasedAmount;
                IMemecoin(memecoin).mint(address(this), memecoinAmount);
                _safeApproveInf(UPT, OUTRUN_AMM_ROUTER);
                _safeApproveInf(memecoin, OUTRUN_AMM_ROUTER);
                (,, uint256 memecoinLiquidity) = IOutrunAMMRouter(OUTRUN_AMM_ROUTER).addLiquidity(
                    UPT,
                    memecoin,
                    SWAP_FEERATE,
                    totalMemecoinFunds,
                    memecoinAmount,
                    totalMemecoinFunds,
                    memecoinAmount,
                    address(this),
                    block.timestamp
                );
                IMemecoin(memecoin).setGenesisLiquidityPool(OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, UPT, memecoin, SWAP_FEERATE));

                // Mint liquidity proof token and deploy liquid proof liquidity
                IMemeLiquidProof(liquidProof).mint(address(this), memecoinLiquidity);
                _safeApproveInf(UPT, OUTRUN_AMM_ROUTER);
                _safeApproveInf(liquidProof, OUTRUN_AMM_ROUTER);
                uint256 liquidProofAmount = memecoinLiquidity / 4;
                IOutrunAMMRouter(OUTRUN_AMM_ROUTER).addLiquidity(
                    UPT,
                    liquidProof,
                    SWAP_FEERATE,
                    totalLiquidProofFunds,
                    liquidProofAmount,
                    totalLiquidProofFunds,
                    liquidProofAmount,
                    address(0),
                    block.timestamp
                );
                claimableLiquidProofs[verseId] = memecoinLiquidity - liquidProofAmount;

                verse.currentStage = Stage.Locked;
                currentStage = Stage.Locked;
            }
        } else if (currentStage == Stage.Locked && currentTime > verse.unlockTime) {
            verse.currentStage = Stage.Unlocked;
            currentStage = Stage.Unlocked;
        }

        emit ChangeStage(verseId, currentStage, yieldVault);
    }

    /**
     * @dev Refund UPT after genesis Failed, total omnichain funds didn't meet the minimum funding requirement
     * @param verseId - Memeverse id
     */
    function refund(uint256 verseId) external whenNotPaused override returns (uint256 userFunds) {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage == Stage.Refund, NotRefundStage(currentStage));
        
        address msgSender = msg.sender;
        userFunds = userTotalFunds[verseId][msgSender];
        require(userFunds > 0, InsufficientUserFunds());
        userTotalFunds[verseId][msgSender] = 0;
        _transferOut(UPT, msgSender, userFunds);
        
        emit Refund(verseId, msgSender, userFunds);
    }

    /**
     * @dev Claim liquidProof in stage Locked
     * @param verseId - Memeverse id
     */
    function claimLiquidProof(uint256 verseId) external whenNotPaused override returns (uint256 amount) {
        amount = claimableLiquidProof(verseId);
        if (amount != 0) {
            address msgSender = msg.sender;
            userTotalFunds[verseId][msgSender] = 0;
            _transferOut(memeverses[verseId].liquidProof, msgSender, amount);

            emit ClaimLiquidProof(verseId, msgSender, amount);
        }
    }

    /**
     * @dev Redeem transaction fees and distribute them to the owner(UPT) and vault(Memecoin)
     * @param verseId - Memeverse id
     * @param botFeeReceiver - Address of AutoBotFee receiver
     * @return govFee - The UPT fee.
     * @return memecoinFee - The memecoin fee.
     * @return autoBotFee - The AutoBotFee.
     * @notice Anyone who calls this method will be rewarded with AutoBotFee.
     */
    function redeemAndDistributeFees(uint256 verseId, address botFeeReceiver) external payable whenNotPaused override 
    returns (uint256 govFee, uint256 memecoinFee, uint256 autoBotFee) {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage >= Stage.Locked, NotReachedLockedStage(currentStage));

        // Memecoin pair
        address memecoin = verse.memecoin;
        IOutrunAMMPair memecoinPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, memecoin, UPT, SWAP_FEERATE));
        (uint256 amount0, uint256 amount1) = memecoinPair.claimMakerFee();
        address token0 = memecoinPair.token0();
        uint256 UPTFee = token0 == UPT ? amount0 : amount1;
        memecoinFee = token0 == memecoin ? amount0 : amount1;

        // LiquidProof pair
        address liquidProof = verse.liquidProof;
        IOutrunAMMPair liquidProofPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, liquidProof, UPT, SWAP_FEERATE));
        (amount0, amount1) = liquidProofPair.claimMakerFee();
        token0 = liquidProofPair.token0();
        uint256 burnedUPT = token0 == UPT ? amount0 : amount1;
        uint256 burnedLiquidProof = token0 == liquidProof ? amount0 : amount1;

        if (UPTFee == 0 && memecoinFee == 0) return (0, 0, 0);

        // Burn the UPT fee and liquidProof fee from liquidProof pair
        if (burnedUPT != 0) IBurnable(UPT).burn(burnedUPT);
        if (burnedLiquidProof != 0) IBurnable(liquidProof).burn(burnedLiquidProof);

        // AutoBot Fee
        unchecked {
            autoBotFee = UPTFee * autoBotFeeRate / RATIO;
            govFee = UPTFee - autoBotFee;
        }
        if (autoBotFee != 0) _transferOut(UPT, botFeeReceiver, autoBotFee);
        
        uint32 govChainId = verse.omnichainIds[0];
        bool isLocalBurned = false;
        if(govChainId == block.chainid) {
            address governor = verse.governor;
            if (governor.code.length == 0) isLocalBurned = true;
            if (govFee != 0) {
                if (isLocalBurned) {
                    IBurnable(UPT).burn(govFee);
                } else {
                    _transferOut(UPT, governor, govFee);
                }
            }

            if (memecoinFee != 0) {
                if (isLocalBurned) {
                    IBurnable(memecoin).burn(memecoinFee);
                } else {
                    address yieldVault = verse.yieldVault;
                    _safeApproveInf(memecoin, yieldVault);
                    IMemecoinYieldVault(yieldVault).accumulateYields(memecoinFee);
                }
            }
        } else {
            uint32 govEndpointId = lzEndpointIds[govChainId];
            
            bytes memory yieldDispatcherOptions = OptionsBuilder.newOptions()
                .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
                .addExecutorLzComposeOption(0, yieldDispatcherGasLimit, 0);

            SendParam memory sendUPTParam;
            MessagingFee memory govMessagingFee;
            if (govFee != 0) {
                sendUPTParam = SendParam({
                    dstEid: govEndpointId,
                    to: bytes32(uint256(uint160(yieldDispatcher))),
                    amountLD: govFee,
                    minAmountLD: 0,
                    extraOptions: yieldDispatcherOptions,
                    composeMsg: abi.encode(verseId, "UPT"),
                    oftCmd: abi.encode()
                });
                govMessagingFee = IOFT(UPT).quoteSend(sendUPTParam, false);
            }

            SendParam memory sendMemecoinParam;
            MessagingFee memory memecoinMessagingFee;
            if (memecoinFee != 0) {
                sendMemecoinParam = SendParam({
                    dstEid: govEndpointId,
                    to: bytes32(uint256(uint160(yieldDispatcher))),
                    amountLD: memecoinFee,
                    minAmountLD: 0,
                    extraOptions: yieldDispatcherOptions,
                    composeMsg: abi.encode(verseId, "Memecoin"),
                    oftCmd: abi.encode()
                });
                memecoinMessagingFee = IOFT(memecoin).quoteSend(sendMemecoinParam, false);
            }

            uint256 govMessagingNativeFee = govMessagingFee.nativeFee;
            uint256 memecoinMessagingNativeFee = memecoinMessagingFee.nativeFee;
            require(msg.value >= govMessagingNativeFee + memecoinMessagingNativeFee, InsufficientLzFee());
            if (govFee != 0) IOFT(UPT).send{value: govMessagingNativeFee}(sendUPTParam, govMessagingFee, msg.sender);
            if (memecoinFee != 0) IOFT(memecoin).send{value: memecoinMessagingNativeFee}(sendMemecoinParam, memecoinMessagingFee, msg.sender);
        }
        
        emit RedeemAndDistributeFees(verseId, isLocalBurned, govFee, memecoinFee, autoBotFee, burnedUPT, burnedLiquidProof);
    }

    /**
     * @dev Burn liquidProof to claim the locked liquidity
     * @param verseId - Memeverse id
     * @param amountInPOL - Burned liquid proof token amount
     */
    function redeemLiquidity(uint256 verseId, uint256 amountInPOL) external whenNotPaused override {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage == Stage.Unlocked, NotUnlockedStage(currentStage));

        address msgSender = msg.sender;
        IMemeLiquidProof(verse.liquidProof).burn(msgSender, amountInPOL);
        address pair = OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, verse.memecoin, UPT, SWAP_FEERATE);
        _transferOut(pair, msgSender, amountInPOL);

        emit RedeemLiquidity(verseId, msgSender, amountInPOL);
    }

    /**
     * @dev Mint liquidProof by add memecoin liquidity when currentStage >= Stage.Locked.
     * @param verseId - Memeverse id
     * @param amountInUPTDesired - Amount of UPT desired
     * @param amountInMemecoinDesired - Amount of memecoin desired
     * @param amountInUPTMin - Minimum amount of UPT
     * @param amountInMemecoinMin - Minimum amount of memecoin
     */
    function mintLiquidProof(
        uint256 verseId, 
        uint256 amountInUPTDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUPTMin,
        uint256 amountInMemecoinMin
    ) external override returns (uint256) {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage >= Stage.Locked, NotReachedLockedStage(currentStage));

        address memecoin = verse.memecoin;
        _transferFrom(IERC20(UPT), msg.sender, address(this), amountInUPTDesired);
        _transferFrom(IERC20(memecoin), msg.sender, address(this), amountInMemecoinDesired);

        _safeApproveInf(UPT, OUTRUN_AMM_ROUTER);
        _safeApproveInf(memecoin, OUTRUN_AMM_ROUTER);
        (uint256 amountInUPTAdded, uint256 amountInMemecoinAdded, uint256 liquidity) = IOutrunAMMRouter(OUTRUN_AMM_ROUTER).addLiquidity(
            UPT,
            memecoin,
            SWAP_FEERATE,
            amountInUPTDesired,
            amountInMemecoinDesired,
            amountInUPTMin,
            amountInMemecoinMin,
            address(this),
            block.timestamp + 600
        );

        uint256 UPTRefund = amountInUPTDesired - amountInUPTAdded;
        uint256 memecoinRefund = amountInMemecoinDesired - amountInMemecoinAdded;
        if (UPTRefund > 0) _transferOut(UPT, msg.sender, UPTRefund);
        if (memecoinRefund > 0) _transferOut(memecoin, msg.sender, memecoinRefund);

        address liquidProof = verse.liquidProof;
        IMemeLiquidProof(liquidProof).mint(msg.sender, liquidity);

        emit MintLiquidProof(verseId, memecoin, liquidProof, msg.sender, liquidity);
        return liquidity;
    }

    /**
     * @dev register memeverse
     * @param name - Name of memecoin
     * @param symbol - Symbol of memecoin
     * @param uri - IPFS URI of memecoin icon
     * @param creator - The creator of memeverse
     * @param uniqueId - Unique verseId
     * @param endTime - Genesis stage end time
     * @param unlockTime - Unlock time of liquidity
     * @param omnichainIds - ChainIds of the token's omnichain(EVM)
     */
    function registerMemeverse(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address creator,
        uint256 uniqueId,
        uint128 endTime,
        uint128 unlockTime,
        uint32[] calldata omnichainIds
    ) external whenNotPaused override {
        require(msg.sender == memeverseRegistrar, PermissionDenied());

        address memecoin = memecoinImplementation.cloneDeterministic(keccak256(abi.encodePacked(symbol, creator, uniqueId)));
        IMemecoin(memecoin).initialize(name, symbol, 18, unlockTime, address(this), LOCAL_LZ_ENDPOINT, address(this));
        _lzConfigure(memecoin, omnichainIds);

        Memeverse memory verse = Memeverse(
            name, 
            symbol, 
            uri, 
            memecoin, 
            creator, 
            address(0), 
            address(0), 
            address(0),
            endTime,
            unlockTime, 
            omnichainIds,
            Stage.Genesis
        );
        memeverses[uniqueId] = verse;
        memecoinToIds[memecoin] = uniqueId;

        emit RegisterMemeverse(uniqueId, verse);
    }

    /**
     * @dev Memecoin Layerzero configure. See: https://docs.layerzero.network/v2/developers/evm/create-lz-oapp/configuring-pathways
     */
    function _lzConfigure(address memecoin, uint32[] memory omnichainIds) internal {
        uint32 currentChainId = uint32(block.chainid);

        // Use default config
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == currentChainId) continue;

            uint32 remoteEndpointId = lzEndpointIds[omnichainId];
            require(remoteEndpointId != 0, InvalidOmnichainId(omnichainId));

            IOAppCore(memecoin).setPeer(remoteEndpointId, bytes32(uint256(uint160(memecoin))));
        }
    }

    /**
     * @dev Remove gas dust from the contract
     */
    function removeGasDust(address receiver) external override {
        uint256 dust = address(this).balance;
        _transferOut(NATIVE, receiver, dust);

        emit RemoveGasDust(receiver, dust);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Set memeverse registrar
     * @param _registrar - Memeverse registrar address
     */
    function setMemeverseRegistrar(address _registrar) external override onlyOwner {
        require(_registrar != address(0), ZeroInput());

        memeverseRegistrar = _registrar;

        emit SetMemeverseRegistrar(_registrar);
    }

    /**
     * @dev Set min totalFunds in launch verse
     * @param _minTotalFunds - Min totalFunds
     */
    function setMinTotalFund(uint256 _minTotalFunds) external override onlyOwner {
        require(_minTotalFunds != 0, ZeroInput());

        minTotalFunds = _minTotalFunds;

        emit SetMinTotalFund(_minTotalFunds);
    }

    /**
     * @dev Set token mint amount based fund
     * @param _fundBasedAmount - Token mint amount based fund
     */
    function setFundBasedAmount(uint256 _fundBasedAmount) external override onlyOwner {
        require(_fundBasedAmount != 0, ZeroInput());

        fundBasedAmount = _fundBasedAmount;

        emit SetFundBasedAmount(_fundBasedAmount);
    }

    /**
     * @dev Set AutoBot fee rate 
     * @param _autoBotFeeRate - AutoBot fee rate
     */
    function setAutoBotFeeRate(uint256 _autoBotFeeRate) external override onlyOwner {
        require(_autoBotFeeRate < RATIO, FeeRateOverFlow());

        autoBotFeeRate = _autoBotFeeRate;

        emit SetAutoBotFeeRate(_autoBotFeeRate);
    }

    /**
     * @dev Set Memecoin implementation logic contract
     * @param _memecoinImplementation - Address of memecoinImplementation
     */
    function setMemecoinImplementation(address _memecoinImplementation) external override onlyOwner {
        require(_memecoinImplementation != address(0), ZeroInput());

        memecoinImplementation = _memecoinImplementation;

        emit SetMemecoinImplementation(_memecoinImplementation);
    }

    /**
     * @dev Set POL implementation logic contract
     * @param _polImplementation - Address of polImplementation
     */
    function setPolImplementation(address _polImplementation) external override onlyOwner {
        require(_polImplementation != address(0), ZeroInput());

        polImplementation = _polImplementation;

        emit SetPolImplementation(_polImplementation);
    }

    /**
     * @dev Set Vault implementation logic contract
     * @param _vaultImplementation - Address of vaultImplementation
     */
    function setVaultImplementation(address _vaultImplementation) external override onlyOwner {
        require(_vaultImplementation != address(0), ZeroInput());

        vaultImplementation = _vaultImplementation;

        emit SetVaultImplementation(_vaultImplementation);
    }

    /**
     * @dev Set memecoin DAO governor implementation logic contract
     * @param _governorImplementation - Address of governorImplementation
     */
    function setGovernorImplementation(address _governorImplementation) external override onlyOwner {
        require(_governorImplementation != address(0), ZeroInput());

        governorImplementation = _governorImplementation;

        emit SetGovernorImplementation(_governorImplementation);
    }

    /**
     * @dev Set memecoin _yieldDispatcher contract
     * @param _yieldDispatcher - Address of _yieldDispatcher
     */
    function setYieldDispatcher(address _yieldDispatcher) external override onlyOwner {
        require(_yieldDispatcher != address(0), ZeroInput());

        yieldDispatcher = _yieldDispatcher;

        emit SetYieldDispatcher(_yieldDispatcher);
    }

    /**
     * @dev Set gas limits for OFT receive and yield dispatcher
     * @param _oftReceiveGasLimit - Gas limit for OFT receive
     * @param _yieldDispatcherGasLimit - Gas limit for yield dispatcher
     */
    function setGasLimits(uint128 _oftReceiveGasLimit, uint128 _yieldDispatcherGasLimit) external override onlyOwner {
        require(_oftReceiveGasLimit > 0 && _yieldDispatcherGasLimit > 0, ZeroInput());

        oftReceiveGasLimit = _oftReceiveGasLimit;
        yieldDispatcherGasLimit = _yieldDispatcherGasLimit;

        emit SetGasLimits(_oftReceiveGasLimit, _yieldDispatcherGasLimit);
    }

    /**
     * @notice Set the layerzero endpoint ids for the given chain ids.
     * @param pairs The pairs of chain ids and endpoint ids to set.
     */
    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            LzEndpointIdPair calldata pair = pairs[i];
            if (pair.chainId == 0 || pair.endpointId == 0) continue;

            lzEndpointIds[pair.chainId] = pair.endpointId;
        }

        emit SetLzEndpointIds(pairs);
    }
}
