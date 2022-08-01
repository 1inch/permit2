// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

/// @title Approve2
/// @author transmissions11 <t11s@paradigm.xyz>
/// @notice Backwards compatible, low-overhead,
/// next generation token approval/meta-tx system.
contract Approve2 {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                          EIP-712 STORAGE/LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps addresses to their current nonces. Used to prevent replay
    /// attacks and allow invalidating in-flight permits via invalidateNonce.
    mapping(address => uint256) public nonces;

    /// @notice Invalidate a specific number of nonces. Can be used
    /// to invalidate in-flight permits before they are executed.
    /// @param noncesToInvalidate The number of nonces to invalidate.
    function invalidateNonces(uint256 noncesToInvalidate) public {
        // Limit how quickly users can invalidate their nonces to
        // ensure no one accidentally invalidates all their nonces.
        require(noncesToInvalidate <= type(uint16).max);

        // Unchecked because counter overflow should
        // be impossible on any reasonable timescale
        // given the cap on noncesToInvalidate above.
        unchecked {
            nonces[msg.sender] += noncesToInvalidate;
        }
    }

    /// @notice The EIP-712 "domain separator" the contract
    /// will use when validating signatures for a given token.
    /// @param token The token to get the domain separator for.
    function DOMAIN_SEPARATOR(address token) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256("Approve2"),
                    keccak256("1"),
                    block.chainid,
                    token // We use the token's address for easy frontend compatibility.
                )
            );
    }

    /*//////////////////////////////////////////////////////////////
                            ALLOWANCE STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps users to tokens to spender addresses and how much they
    /// are approved to spend the amount of that token the user has approved.
    mapping(address => mapping(ERC20 => mapping(address => uint256))) public allowance;

    /// @notice Approve a spender to transfer a specific
    /// amount of a specific ERC20 token from the sender.
    /// @param token The token to approve.
    /// @param spender The spender address to approve.
    /// @param amount The amount of the token to approve.
    function approve(
        ERC20 token,
        address spender,
        uint256 amount
    ) external {
        allowance[msg.sender][token][spender] = amount;
    }

    /*//////////////////////////////////////////////////////////////
                              PERMIT LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Permit a user to spend a given amount of another user's
    /// approved amount of the given token via the owner's EIP-712 signature.
    /// @param token The token to permit spending.
    /// @param owner The user to permit spending from.
    /// @param spender The user to permit spending to.
    /// @param amount The amount to permit spending.
    /// @param deadline  The timestamp after which the signature is no longer valid.
    /// @param v Must produce valid secp256k1 signature from the owner along with r and s.
    /// @param r Must produce valid secp256k1 signature from the owner along with v and s.
    /// @param s Must produce valid secp256k1 signature from the owner along with r and v.
    /// @dev May fail if the owner's nonce was invalidated in-flight by invalidateNonce.
    function permit(
        ERC20 token,
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        // Ensure the signature's deadline has not already passed.
        require(deadline >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            // Recover the signer address from the signature.
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(address(token)),
                        keccak256(
                            abi.encode(
                                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                                owner,
                                spender,
                                amount,
                                nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            // Ensure the signature is valid and the signer is the owner.
            require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNER");

            // Set the allowance of the spender to the given amount.
            allowance[recoveredAddress][token][spender] = amount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                             TRANSFER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer approved tokens from one address to another.
    /// @param token The token to transfer.
    /// @param from The address to transfer from.
    /// @param to The address to transfer to.
    /// @param amount The amount of tokens to transfer.
    /// @dev Requires either the from address to have approved at least the desired amount
    /// of tokens or msg.sender to be approved to manage all of the from addresses's tokens.
    function transferFrom(
        ERC20 token,
        address from,
        address to,
        uint256 amount
    ) external {
        uint256 allowed = allowance[from][token][msg.sender]; // Saves gas for limited approvals.

        // If the from address has set an unlimited approval, we'll go straight to the transfer.
        if (allowed != type(uint256).max) allowance[from][token][msg.sender] = allowed - amount;

        // Transfer the tokens from the from address to the recipient.
        token.safeTransferFrom(from, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             LOCKDOWN LOGIC
    //////////////////////////////////////////////////////////////*/

    struct Approval {
        ERC20 token;
        address spender;
    }

    /// @notice Enables performing a "lockdown" of the sender's Approve2
    /// identity by batch revoking approvals and invalidating nonces.
    /// @param approvalsToRevoke An array of approvals to revoke.
    /// @param noncesToInvalidate  The number of nonces to invalidate.
    function lockdown(Approval[] calldata approvalsToRevoke, uint256 noncesToInvalidate) external {
        // Unchecked because counter overflow is impossible
        // in any environment with reasonable gas limits.
        unchecked {
            // Revoke allowances for each pair of spenders and tokens.
            for (uint256 i = 0; i < approvalsToRevoke.length; ++i) {
                // TODO: Can this be optimized?
                delete allowance[msg.sender][approvalsToRevoke[i].token][approvalsToRevoke[i].spender];
            }
        }

        // Will revert if trying to invalidate
        // more than type(uint16).max nonces.
        invalidateNonces(noncesToInvalidate);
    }
}
