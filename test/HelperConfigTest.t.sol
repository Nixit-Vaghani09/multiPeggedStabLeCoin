//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/forge-std/src/Test.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract HelperConfigTest is Test {
    HelperConfig helperConfig;
    MockV3Aggregator mockV3Aggregator;
    MockV3Aggregator mockV3Aggregator8Decimals;
    ERC20Mock collateral;
    ERC20Mock collateral2;

    uint256 chainId;
    address owner = address(this);
    address nonOwner = makeAddr("nonOwner");
    bytes32 constant PYTH_ID_1 = bytes32(uint256(1));
    bytes32 constant PYTH_ID_2 = bytes32(uint256(2));

    event CollateralAdded(
        uint256 chainId,
        address collateral,
        address pricefeed
    );

    function setUp() public {
        chainId = block.chainid;
        helperConfig = new HelperConfig();
        
        collateral = new ERC20Mock("Token1", "TK1", owner, 1000 ether);
        collateral2 = new ERC20Mock("Token2", "TK2", owner, 1000 ether);

        mockV3Aggregator = new MockV3Aggregator(18, 2000e18); // 18 decimals
        mockV3Aggregator8Decimals = new MockV3Aggregator(8, 2000e8); // 8 decimals
    }

    // ──────────────────────────────────────────────
    //  Access Control Tests
    // ──────────────────────────────────────────────

    function testNonOwnerCannotAddCollateral() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
    }

    function testNonOwnerCannotUpdatePythId() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        helperConfig.updatePythId( address(collateral), PYTH_ID_2);
    }

    function testNonOwnerCannotUpdatePriceFeed() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        helperConfig.updatePriceFeed(chainId, address(collateral), address(mockV3Aggregator8Decimals));
    }

    function testNonOwnerCannotSetCollateralEnabled() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        helperConfig.setCollateralEnabled(chainId, address(collateral), false);
    }

    // ──────────────────────────────────────────────
    //  Add Collateral Tests
    // ──────────────────────────────────────────────

    function testAddCollateralRevertsIfZeroAddress() public {
        vm.expectRevert(HelperConfig.HelperConfig__addressCantBeZero.selector);
        helperConfig.addCollateral(chainId, address(0), address(mockV3Aggregator), PYTH_ID_1);

        vm.expectRevert(HelperConfig.HelperConfig__addressCantBeZero.selector);
        helperConfig.addCollateral(chainId, address(collateral), address(0), PYTH_ID_1);
    }

    function testAddCollateralSuccessAndEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit CollateralAdded(chainId, address(collateral), address(mockV3Aggregator));
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);

        assertTrue(helperConfig.getCollateralAllowed(chainId, address(collateral)));
        assertEq(helperConfig.getPythPriceId(address(collateral), chainId), PYTH_ID_1);
        (address feed, uint8 decimals) = helperConfig.getFeed(chainId, address(collateral));
        assertEq(feed, address(mockV3Aggregator));
        assertEq(decimals, 18);
    }

    // ──────────────────────────────────────────────
    //  Update Tests
    // ──────────────────────────────────────────────

    function testUpdatePythId() public {
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
        
        helperConfig.updatePythId( address(collateral), PYTH_ID_2);
        assertEq(helperConfig.getPythPriceId(address(collateral), chainId), PYTH_ID_2);
    }

    function testUpdatePriceFeed() public {
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
        
        helperConfig.updatePriceFeed(chainId, address(collateral), address(mockV3Aggregator8Decimals));
        (address feed, ) = helperConfig.getFeed(chainId, address(collateral));
        assertEq(feed, address(mockV3Aggregator8Decimals));
    }

    function testSetCollateralEnabled() public {
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
        
        assertTrue(helperConfig.getCollateralAllowed(chainId, address(collateral)));
        
        helperConfig.setCollateralEnabled(chainId, address(collateral), false);
        assertFalse(helperConfig.getCollateralAllowed(chainId, address(collateral)));
    }

    // ──────────────────────────────────────────────
    //  Getter Tests (Price)
    // ──────────────────────────────────────────────

    function testGetCollateralPriceRevertsIfNotAllowed() public {
        vm.expectRevert(HelperConfig.HelperConfig__CollateralDoesntExsist.selector);
        helperConfig.getCollateralPrice(chainId, address(collateral));
    }

    function testGetCollateralPriceRevertsIfPriceZeroOrNegative() public {
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
        
        mockV3Aggregator.updateAnswer(0);
        vm.expectRevert(HelperConfig.HelperConfig__PriceMustBeGreateThanZero.selector);
        helperConfig.getCollateralPrice(chainId, address(collateral));

        mockV3Aggregator.updateAnswer(-1);
        vm.expectRevert(HelperConfig.HelperConfig__PriceMustBeGreateThanZero.selector);
        helperConfig.getCollateralPrice(chainId, address(collateral));
    }

    function testGetCollateralPriceReturnsCorrectNormalizedPrice() public {
        // 18 decimals aggregator
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
        uint256 price18 = helperConfig.getCollateralPrice(chainId, address(collateral));
        assertEq(price18, 2000e18); // 1e18 / 1e18 = 1, so 2000e18 * 1 = 2000e18

        // 8 decimals aggregator
        helperConfig.addCollateral(chainId, address(collateral2), address(mockV3Aggregator8Decimals), PYTH_ID_2);
        uint256 price8 = helperConfig.getCollateralPrice(chainId, address(collateral2));
        assertEq(price8, 2000e18); // 1e18 / 1e8 = 1e10, so 2000e8 * 1e10 = 2000e18
    }

    // ──────────────────────────────────────────────
    //  Getter Tests (Collections)
    // ──────────────────────────────────────────────

    function testGetEnabledCollateralPriceFeeds() public {
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
        helperConfig.addCollateral(chainId, address(collateral2), address(mockV3Aggregator8Decimals), PYTH_ID_2);

        address[] memory feeds = helperConfig.getEnabledCollateralPriceFeeds(chainId);
        assertEq(feeds.length, 2);
        assertEq(feeds[0], address(mockV3Aggregator));
        assertEq(feeds[1], address(mockV3Aggregator8Decimals));

        // Disable one
        helperConfig.setCollateralEnabled(chainId, address(collateral), false);
        feeds = helperConfig.getEnabledCollateralPriceFeeds(chainId);
        assertEq(feeds.length, 1);
        assertEq(feeds[0], address(mockV3Aggregator8Decimals));
    }

    function testGetAllCollaterals() public {
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
        helperConfig.addCollateral(chainId, address(collateral2), address(mockV3Aggregator8Decimals), PYTH_ID_2);

        address[] memory allColls = helperConfig.getAllCollaterals(chainId);
        assertEq(allColls.length, 2);
        assertEq(allColls[0], address(collateral));
        assertEq(allColls[1], address(collateral2));
    }

    function testGetEnabledCollaterals() public {
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
        helperConfig.addCollateral(chainId, address(collateral2), address(mockV3Aggregator8Decimals), PYTH_ID_2);

        // Disable collateral 1
        helperConfig.setCollateralEnabled(chainId, address(collateral), false);

        address[] memory enabledColls = helperConfig.getEnabledCollaterals(chainId);
        assertEq(enabledColls.length, 1);
        assertEq(enabledColls[0], address(collateral2));
    }

    // ──────────────────────────────────────────────
    //  Getter Tests (Misc)
    // ──────────────────────────────────────────────

    function testGetFeedRevertsIfNotAllowed() public {
        vm.expectRevert(HelperConfig.HelperConfig__CollateralDoesntExsist.selector);
        helperConfig.getFeed(chainId, address(collateral));
    }

    function testGetPythPriceIdRevertsIfNotAllowed() public {
        vm.expectRevert(HelperConfig.HelperConfig__CollateralDoesntExsist.selector);
        helperConfig.getPythPriceId(address(collateral), chainId);
    }


    function testGetCollateralAllowed() public {
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
        assertTrue(helperConfig.getCollateralAllowed(chainId, address(collateral)));
        helperConfig.setCollateralEnabled(chainId, address(collateral), false);
        assertFalse(helperConfig.getCollateralAllowed(chainId, address(collateral)));
    }

    function testEnabledFeedsEmptyWhenAllDisabled() public {
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PYTH_ID_1);
        helperConfig.addCollateral(chainId, address(collateral2), address(mockV3Aggregator8Decimals), PYTH_ID_2);
        // disable both
        helperConfig.setCollateralEnabled(chainId, address(collateral), false);
        helperConfig.setCollateralEnabled(chainId, address(collateral2), false);
        address[] memory feeds = helperConfig.getEnabledCollateralPriceFeeds(chainId);
        assertEq(feeds.length, 0);
        address[] memory enabledColls = helperConfig.getEnabledCollaterals(chainId);
        assertEq(enabledColls.length, 0);
    }
}