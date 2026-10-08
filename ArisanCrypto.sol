// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ArisanCrypto
 * @notice Celengan digital bersama (arisan) tanpa perantara.
 *
 * Alur singkat:
 *  1. Peserta `join()` dengan menyetor JAMINAN (collateral).
 *  2. Saat kuota penuh, arisan otomatis dimulai (ronde 0).
 *  3. Tiap ronde, semua peserta `contribute()` setoran tetap.
 *  4. Setelah semua bayar ATAU deadline lewat, siapa saja boleh `closeRound()`.
 *     Pemenang ronde = peserta sesuai urutan join. Peserta yang telat
 *     bayar otomatis ditalangi dari jaminannya.
 *  5. Pemenang menarik uang lewat `withdraw()`.
 *  6. Setelah semua ronde selesai, sisa jaminan ditarik lewat `withdrawCollateral()`.
 *
 * Catatan: ini project belajar. Lakukan audit sebelum dipakai uang sungguhan.
 */
contract ArisanCrypto {
    // ---------------------------------------------------------------
    // Tipe & state
    // ---------------------------------------------------------------
    enum Status {
        Open, // menunggu peserta
        Active, // arisan berjalan
        Completed // semua ronde selesai
    }

    uint256 public constant MAX_MEMBERS_LIMIT = 50; // batasi loop agar gas aman

    address public immutable organizer;
    uint256 public immutable contributionAmount; // setoran per ronde (wei)
    uint256 public immutable maxMembers;
    uint256 public immutable roundDuration; // detik

    Status public status;
    uint256 public currentRound; // mulai dari 0
    uint256 public roundDeadline;

    address[] private members; // urutan join = urutan giliran menang

    mapping(address => bool) public isMember;
    mapping(address => uint256) public collateral; // jaminan tersisa
    mapping(address => uint256) public pendingWithdrawals; // saldo yang bisa ditarik
    mapping(address => bool) public hasDefaulted; // pernah ditalangi jaminan
    mapping(uint256 => mapping(address => bool)) public hasPaid; // ronde => peserta => sudah bayar
    mapping(uint256 => uint256) public paidCount; // ronde => jumlah yang sudah bayar

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------
    event Joined(address indexed member, uint256 totalMembers);
    event Left(address indexed member);
    event Started(uint256 firstDeadline);
    event Contributed(uint256 indexed round, address indexed member);
    event Covered(uint256 indexed round, address indexed member, uint256 amount);
    event RoundClosed(uint256 indexed round, address indexed winner, uint256 prize);
    event Completed(uint256 totalRounds);
    event Withdrawn(address indexed member, uint256 amount);
    event CollateralWithdrawn(address indexed member, uint256 amount);

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------
    constructor(uint256 _contributionAmount, uint256 _maxMembers, uint256 _roundDuration) {
        require(_contributionAmount > 0, "Setoran harus > 0");
        require(_maxMembers >= 2 && _maxMembers <= MAX_MEMBERS_LIMIT, "Peserta 2-50");
        require(_roundDuration >= 1 hours, "Durasi min 1 jam");

        organizer = msg.sender;
        contributionAmount = _contributionAmount;
        maxMembers = _maxMembers;
        roundDuration = _roundDuration;
        status = Status.Open;
    }

    // ---------------------------------------------------------------
    // Fase 1: pendaftaran
    // ---------------------------------------------------------------

    /// @notice Jaminan = setoran x (jumlah peserta - 1).
    function requiredCollateral() public view returns (uint256) {
        return contributionAmount * (maxMembers - 1);
    }

    function join() external payable {
        require(status == Status.Open, "Pendaftaran ditutup");
        require(!isMember[msg.sender], "Sudah terdaftar");
        require(msg.value == requiredCollateral(), "Jaminan tidak sesuai");

        isMember[msg.sender] = true;
        collateral[msg.sender] = msg.value;
        members.push(msg.sender);

        emit Joined(msg.sender, members.length);

        // Kuota penuh -> otomatis mulai
        if (members.length == maxMembers) {
            status = Status.Active;
            roundDeadline = block.timestamp + roundDuration;
            emit Started(roundDeadline);
        }
    }

    /// @notice Keluar sebelum arisan dimulai, jaminan dikembalikan.
    function leave() external {
        require(status == Status.Open, "Arisan sudah berjalan");
        require(isMember[msg.sender], "Bukan peserta");

        // Hapus dari array sambil menjaga urutan
        uint256 len = members.length;
        for (uint256 i = 0; i < len; i++) {
            if (members[i] == msg.sender) {
                for (uint256 j = i; j < len - 1; j++) {
                    members[j] = members[j + 1];
                }
                members.pop();
                break;
            }
        }

        isMember[msg.sender] = false;
        uint256 refund = collateral[msg.sender];
        collateral[msg.sender] = 0;

        (bool ok, ) = payable(msg.sender).call{value: refund}("");
        require(ok, "Refund gagal");
        emit Left(msg.sender);
    }

    // ---------------------------------------------------------------
    // Fase 2: setoran tiap ronde
    // ---------------------------------------------------------------

    function contribute() external payable {
        require(status == Status.Active, "Arisan tidak aktif");
        require(isMember[msg.sender], "Bukan peserta");
        require(block.timestamp <= roundDeadline, "Deadline lewat");
        require(msg.value == contributionAmount, "Nominal salah");
        require(!hasPaid[currentRound][msg.sender], "Sudah bayar ronde ini");

        hasPaid[currentRound][msg.sender] = true;
        paidCount[currentRound] += 1;

        emit Contributed(currentRound, msg.sender);
    }

    /**
     * @notice Tutup ronde & tentukan pemenang. Boleh dipanggil siapa saja
     *         (tidak bergantung pada organizer).
     */
    function closeRound() external {
        require(status == Status.Active, "Arisan tidak aktif");
        require(
            paidCount[currentRound] == members.length || block.timestamp > roundDeadline,
            "Ronde belum bisa ditutup"
        );

        uint256 round = currentRound;
        address winner = members[round];
        uint256 prize = contributionAmount * members.length;

        // 1) Kreditkan hadiah penuh dulu ke pemenang.
        pendingWithdrawals[winner] += prize;

        // 2) Talangi peserta yang belum bayar.
        if (paidCount[round] < members.length) {
            for (uint256 i = 0; i < members.length; i++) {
                address m = members[i];
                if (!hasPaid[round][m]) {
                    hasDefaulted[m] = true;
                    _coverMember(round, m, winner);
                }
            }
        }

        emit RoundClosed(round, winner, prize);

        // 3) Lanjut ronde / selesai
        currentRound = round + 1;
        if (currentRound == members.length) {
            status = Status.Completed;
            emit Completed(members.length);
        } else {
            roundDeadline = block.timestamp + roundDuration;
        }
    }

    /// @dev Ambil setoran yang kurang dari jaminan; jika jaminan habis, dari saldo kemenangan;
    ///      jika tetap kurang, hadiah pemenang ronde ini yang berkurang.
    function _coverMember(uint256 round, address m, address winner) private {
        uint256 c = contributionAmount;

        if (collateral[m] >= c) {
            collateral[m] -= c;
        } else if (pendingWithdrawals[m] >= c) {
            pendingWithdrawals[m] -= c;
        } else {
            // Jaminan & saldo tidak cukup: potong hadiah pemenang agar dana tetap konsisten.
            uint256 w = pendingWithdrawals[winner];
            pendingWithdrawals[winner] = w >= c ? w - c : 0;
            return;
        }
        emit Covered(round, m, c);
    }

    // ---------------------------------------------------------------
    // Fase 3: penarikan (pull payment)
    // ---------------------------------------------------------------

    /// @notice Tarik hadiah kemenangan.
    /// @dev Peserta yang pernah menunggak baru bisa menarik setelah arisan selesai,
    ///      agar sisa tunggakan masih bisa dipotong dari saldonya.
    function withdraw() external {
        require(
            !hasDefaulted[msg.sender] || status == Status.Completed,
            "Terkunci sampai arisan selesai"
        );
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Tidak ada saldo");

        pendingWithdrawals[msg.sender] = 0; // effects sebelum interaction
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer gagal");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Tarik sisa jaminan setelah arisan selesai.
    function withdrawCollateral() external {
        require(status == Status.Completed, "Arisan belum selesai");
        uint256 amount = collateral[msg.sender];
        require(amount > 0, "Tidak ada jaminan");

        collateral[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer gagal");
        emit CollateralWithdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------
    // View helpers (untuk frontend)
    // ---------------------------------------------------------------

    function getMembers() external view returns (address[] memory) {
        return members;
    }

    function memberCount() external view returns (uint256) {
        return members.length;
    }

    function currentWinner() external view returns (address) {
        require(status == Status.Active, "Arisan tidak aktif");
        return members[currentRound];
    }
}
