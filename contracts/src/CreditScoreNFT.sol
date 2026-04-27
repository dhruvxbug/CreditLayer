// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./interfaces/ICreditScoreNFT.sol";

/// @title CreditScoreNFT
/// @notice Soul-bound ERC-721 that stores on-chain credit scores for CreditLayer.
///         Each wallet may hold exactly one token. Scores are updated exclusively
///         by the authorised oracle and enforce a 24-hour cooldown between updates.
///         Transfers are permanently disabled — the token is non-transferable.
contract CreditScoreNFT is ERC721, Ownable, ICreditScoreNFT {
    using Strings for uint256;
    using Strings for uint16;
    using Strings for uint8;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice On-chain credit profile attached to each minted token
    struct CreditProfile {
        address wallet;
        uint16  score;
        uint64  lastUpdated;
        bool    zkVerified;
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Minimum time between score updates for a single token
    uint256 public constant UPDATE_COOLDOWN = 24 hours;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The oracle address authorised to mint and update scores
    address public oracle;

    /// @notice Maps a wallet address to its token ID (0 means no token)
    mapping(address => uint256) public walletToTokenId;

    /// @notice Maps a token ID to its credit profile
    mapping(uint256 => CreditProfile) internal _profiles;

    /// @notice Next token ID to be minted (starts at 1)
    uint256 private _nextTokenId;

    // -------------------------------------------------------------------------
    // Events (in addition to those declared in ICreditScoreNFT)
    // -------------------------------------------------------------------------

    /// @notice Emitted when a credit score is updated
    event ScoreUpdated(
        address indexed wallet,
        uint256 indexed tokenId,
        uint16  newScore,
        uint8   tier,
        bool    zkVerified
    );

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param initialOwner The address that will own this contract (via Ownable)
    /// @param _oracle      The initial oracle address authorised to mint/update
    constructor(address initialOwner, address _oracle)
        ERC721("CreditLayer Score", "CLSCORE")
        Ownable(initialOwner)
    {
        oracle = _oracle;
        _nextTokenId = 1;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOracle() {
        if (msg.sender != oracle) revert UnauthorizedOracle();
        _;
    }

    // -------------------------------------------------------------------------
    // Soul-bound overrides — all transfers are permanently disabled
    // -------------------------------------------------------------------------

    /// @dev Block all ERC-721 transfers; soul-bound tokens cannot move.
    function transferFrom(
        address, /*from*/
        address, /*to*/
        uint256  /*tokenId*/
    ) public pure override {
        revert SoulBoundToken();
    }

    /// @dev Block safeTransferFrom (4-arg variant with data).
    ///      In OZ v5, the 3-arg safeTransferFrom is a non-virtual final function
    ///      that delegates here, so overriding this single function is sufficient
    ///      to block all safe-transfer paths.
    function safeTransferFrom(
        address, /*from*/
        address, /*to*/
        uint256, /*tokenId*/
        bytes memory /*data*/
    ) public pure override {
        revert SoulBoundToken();
    }

    // -------------------------------------------------------------------------
    // Oracle-gated write functions
    // -------------------------------------------------------------------------

    /// @inheritdoc ICreditScoreNFT
    function mintScore(address to) external override onlyOracle returns (uint256 tokenId) {
        if (walletToTokenId[to] != 0) revert("CreditScoreNFT: wallet already has token");

        tokenId = _nextTokenId;
        unchecked { _nextTokenId++; }

        _safeMint(to, tokenId);

        _profiles[tokenId] = CreditProfile({
            wallet:     to,
            score:      0,
            lastUpdated: 0,
            zkVerified: false
        });

        walletToTokenId[to] = tokenId;
    }

    /// @inheritdoc ICreditScoreNFT
    function updateScore(
        uint256 tokenId,
        uint16  newScore,
        bool    zkVerified
    ) external override onlyOracle {
        CreditProfile storage profile = _profiles[tokenId];

        // Enforce 24-hour cooldown
        uint64 nextAllowed = profile.lastUpdated + uint64(UPDATE_COOLDOWN);
        if (profile.lastUpdated != 0 && block.timestamp < nextAllowed) {
            revert CooldownNotExpired(nextAllowed);
        }

        profile.score       = newScore;
        profile.lastUpdated = uint64(block.timestamp);
        profile.zkVerified  = zkVerified;

        uint8 tier = getTier(newScore);

        emit ScoreUpdated(profile.wallet, tokenId, newScore, tier, zkVerified);
    }

    // -------------------------------------------------------------------------
    // Read functions
    // -------------------------------------------------------------------------

    /// @inheritdoc ICreditScoreNFT
    function getScore(address wallet)
        external
        view
        override
        returns (uint16 score, uint8 tier, bool zkVerified)
    {
        uint256 tokenId = walletToTokenId[wallet];
        CreditProfile storage profile = _profiles[tokenId];
        score      = profile.score;
        tier       = getTier(profile.score);
        zkVerified = profile.zkVerified;
    }

    /// @inheritdoc ICreditScoreNFT
    function getTier(uint16 score) public pure override returns (uint8 tier) {
        if (score >= 800) return 3;
        if (score >= 600) return 2;
        if (score >= 300) return 1;
        return 0;
    }

    /// @inheritdoc ICreditScoreNFT
    function getTokenId(address wallet) external view override returns (uint256) {
        return walletToTokenId[wallet];
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Update the authorised oracle address
    /// @param newOracle Address of the new oracle
    function setOracle(address newOracle) external onlyOwner {
        oracle = newOracle;
    }

    // -------------------------------------------------------------------------
    // On-chain SVG tokenURI
    // -------------------------------------------------------------------------

    /// @notice Returns a fully on-chain base64-encoded JSON metadata string
    ///         including an SVG image that reflects the token's credit profile.
    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        _requireOwned(tokenId);

        CreditProfile storage profile = _profiles[tokenId];
        uint8  tier       = getTier(profile.score);
        string memory svg = _buildSVG(profile.score, tier, profile.zkVerified);

        string memory json = string(abi.encodePacked(
            '{"name":"CreditLayer Score #', tokenId.toString(), '"',
            ',"description":"A soul-bound credit score NFT issued by CreditLayer."',
            ',"attributes":[',
                '{"trait_type":"Score","value":', uint256(profile.score).toString(), '},',
                '{"trait_type":"Tier","value":"', _tierName(tier), '"},',
                '{"trait_type":"ZK Verified","value":', profile.zkVerified ? 'true' : 'false', '}',
            ']',
            ',"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '"',
            '}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    // -------------------------------------------------------------------------
    // Internal SVG helpers
    // -------------------------------------------------------------------------

    /// @dev Returns the hex background colour for a given tier.
    function _tierBgColor(uint8 tier) internal pure returns (string memory) {
        if (tier == 3) return "#1a1400";  // deep gold background
        if (tier == 2) return "#0d1a1a";  // deep silver-teal background
        if (tier == 1) return "#1a0e00";  // deep bronze background
        return "#111111";                  // unverified dark grey
    }

    /// @dev Returns the primary accent colour for a given tier.
    function _tierAccentColor(uint8 tier) internal pure returns (string memory) {
        if (tier == 3) return "#FFD700";  // gold
        if (tier == 2) return "#C0C0C0";  // silver
        if (tier == 1) return "#CD7F32";  // bronze
        return "#555555";                  // grey
    }

    /// @dev Returns the human-readable tier name.
    function _tierName(uint8 tier) internal pure returns (string memory) {
        if (tier == 3) return "GOLD";
        if (tier == 2) return "SILVER";
        if (tier == 1) return "BRONZE";
        return "UNVERIFIED";
    }

    /// @dev Builds the full SVG string for the token.
    function _buildSVG(
        uint16 score,
        uint8  tier,
        bool   zkVerified
    ) internal pure returns (string memory) {
        string memory bg     = _tierBgColor(tier);
        string memory accent = _tierAccentColor(tier);
        string memory name   = _tierName(tier);

        // Progress bar width: score / 1000 * 320 (bar max-width 320px, starting x=40)
        uint256 barWidth = (uint256(score) * 320) / 1000;

        string memory zkBadge = zkVerified
            ? string(abi.encodePacked(
                '<g transform="translate(310,30)">',
                  '<circle r="12" fill="#22c55e"/>',
                  '<text x="0" y="5" text-anchor="middle" font-size="14" fill="white" font-family="monospace">&#10003;</text>',
                '</g>'
              ))
            : "";

        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 240" width="400" height="240">',

            // Background
            '<rect width="400" height="240" rx="16" fill="', bg, '"/>',

            // Outer border ring using accent colour
            '<rect x="4" y="4" width="392" height="232" rx="13" fill="none" stroke="', accent, '" stroke-width="2" opacity="0.6"/>',

            // Title
            '<text x="40" y="42" font-family="monospace,Courier New" font-size="18" font-weight="bold" fill="', accent, '">CreditLayer</text>',

            // ZK verified badge (top-right)
            zkBadge,

            // Large score number centred
            '<text x="200" y="140" text-anchor="middle" font-family="monospace,Courier New" font-size="80" font-weight="bold" fill="', accent, '" opacity="0.95">',
            uint256(score).toString(),
            '</text>',

            // Tier label below score
            '<text x="200" y="172" text-anchor="middle" font-family="monospace,Courier New" font-size="14" fill="', accent, '" letter-spacing="4">',
            name,
            '</text>',

            // Progress bar track
            '<rect x="40" y="195" width="320" height="10" rx="5" fill="#333333"/>',

            // Progress bar fill
            '<rect x="40" y="195" width="', barWidth.toString(), '" height="10" rx="5" fill="', accent, '"/>',

            // Score range labels
            '<text x="40" y="222" font-family="monospace,Courier New" font-size="10" fill="#666666">0</text>',
            '<text x="352" y="222" font-family="monospace,Courier New" font-size="10" fill="#666666" text-anchor="end">1000</text>',

            '</svg>'
        ));
    }
}
