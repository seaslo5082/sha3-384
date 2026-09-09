package sha3_384_pkg;

    // ================================================================
    // SHA3-384 parameters
    //
    // Keccak state:
    //      1600 bits = 25 lanes * 64 bits
    //
    // SHA3-384:
    //      digest   = 384 bits = 48 bytes
    //      capacity = 768 bits
    //      rate     = 1600 - 768
    //               = 832 bits
    //               = 104 bytes
    //
    // SHA-3 domain separation:
    //      0x06
    //
    // Final padding MSB:
    //      0x80
    // ================================================================

    localparam int SHA3_384_RATE_BYTES   = 104;
    localparam int SHA3_384_DIGEST_BYTES = 48;


    // ================================================================
    // rotate-left 64-bit
    //
    // Keccak Rho step requires rotating every 64-bit lane by a
    // different number of bits.
    //
    // sh == 0 must be handled separately because:
    //
    //     value >> (64 - 0)
    //
    // means shifting by 64 bits, which is best avoided.
    // ================================================================
    function automatic bit [63:0] rotl64(
        input bit [63:0] value,
        input int unsigned sh
    );

        if (sh == 0)
            rotl64 = value;
        else
            rotl64 = (value << sh) | (value >> (64 - sh));

    endfunction



    // ================================================================
    // Keccak Rho rotation offsets
    //
    // Coordinate:
    //
    //     A[x][y]
    //
    // Our flattened state representation is:
    //
    //     state[x + 5*y]
    //
    // ================================================================
    function automatic int unsigned rho_offset(
        input int x,
        input int y
    );

        case (y)

            0: begin
                case (x)
                    0: rho_offset =  0;
                    1: rho_offset =  1;
                    2: rho_offset = 62;
                    3: rho_offset = 28;
                    4: rho_offset = 27;
                endcase
            end

            1: begin
                case (x)
                    0: rho_offset = 36;
                    1: rho_offset = 44;
                    2: rho_offset =  6;
                    3: rho_offset = 55;
                    4: rho_offset = 20;
                endcase
            end

            2: begin
                case (x)
                    0: rho_offset =  3;
                    1: rho_offset = 10;
                    2: rho_offset = 43;
                    3: rho_offset = 25;
                    4: rho_offset = 39;
                endcase
            end

            3: begin
                case (x)
                    0: rho_offset = 41;
                    1: rho_offset = 45;
                    2: rho_offset = 15;
                    3: rho_offset = 21;
                    4: rho_offset =  8;
                endcase
            end

            4: begin
                case (x)
                    0: rho_offset = 18;
                    1: rho_offset =  2;
                    2: rho_offset = 61;
                    3: rho_offset = 56;
                    4: rho_offset = 14;
                endcase
            end

        endcase

    endfunction



    // ================================================================
    // Keccak-f[1600] round constants
    //
    // Keccak-f[1600] always executes exactly 24 rounds.
    //
    // The round constant is XORed into lane A[0][0]
    // during the Iota step.
    // ================================================================
    function automatic bit [63:0] keccak_round_constant(
        input int round
    );

        case (round)

             0: keccak_round_constant = 64'h0000000000000001;
             1: keccak_round_constant = 64'h0000000000008082;
             2: keccak_round_constant = 64'h800000000000808A;
             3: keccak_round_constant = 64'h8000000080008000;
             4: keccak_round_constant = 64'h000000000000808B;
             5: keccak_round_constant = 64'h0000000080000001;
             6: keccak_round_constant = 64'h8000000080008081;
             7: keccak_round_constant = 64'h8000000000008009;

             8: keccak_round_constant = 64'h000000000000008A;
             9: keccak_round_constant = 64'h0000000000000088;
            10: keccak_round_constant = 64'h0000000080008009;
            11: keccak_round_constant = 64'h000000008000000A;
            12: keccak_round_constant = 64'h000000008000808B;
            13: keccak_round_constant = 64'h800000000000008B;
            14: keccak_round_constant = 64'h8000000000008089;
            15: keccak_round_constant = 64'h8000000000008003;

            16: keccak_round_constant = 64'h8000000000008002;
            17: keccak_round_constant = 64'h8000000000000080;
            18: keccak_round_constant = 64'h000000000000800A;
            19: keccak_round_constant = 64'h800000008000000A;
            20: keccak_round_constant = 64'h8000000080008081;
            21: keccak_round_constant = 64'h8000000000008080;
            22: keccak_round_constant = 64'h0000000080000001;
            23: keccak_round_constant = 64'h8000000080008008;

            default:
                keccak_round_constant = 64'h0;

        endcase

    endfunction



    // ================================================================
    // Keccak-f[1600]
    //
    // state:
    //
    //     25 lanes
    //     each lane = 64 bits
    //
    // Flattening rule:
    //
    //     index = x + 5*y
    //
    //
    // Every Keccak round performs:
    //
    //     Theta
    //     Rho
    //     Pi
    //     Chi
    //     Iota
    //
    // ================================================================
    task automatic keccak_f1600(
        inout bit [63:0] state [0:24]
    );

        bit [63:0] C [0:4];
        bit [63:0] D [0:4];

        bit [63:0] B [0:24];

        int x;
        int y;
        int round;

        int src_idx;
        int dst_idx;

        int new_x;
        int new_y;

        int unsigned rot;


        // ------------------------------------------------------------
        // Keccak-f[1600] = 24 rounds
        // ------------------------------------------------------------
        for (round = 0; round < 24; round++) begin


            // ========================================================
            // 1. THETA
            //
            // Compute parity of each x-column:
            //
            // C[x] =
            //     A[x,0] ^
            //     A[x,1] ^
            //     A[x,2] ^
            //     A[x,3] ^
            //     A[x,4]
            //
            // ========================================================
            for (x = 0; x < 5; x++) begin

                C[x] =
                      state[x + 5*0]
                    ^ state[x + 5*1]
                    ^ state[x + 5*2]
                    ^ state[x + 5*3]
                    ^ state[x + 5*4];

            end


            // --------------------------------------------------------
            // D[x] = C[x-1] XOR ROT(C[x+1], 1)
            //
            // +4 and +1 implement modulo-5 indexing.
            // --------------------------------------------------------
            for (x = 0; x < 5; x++) begin

                D[x] =
                      C[(x + 4) % 5]
                    ^ rotl64(C[(x + 1) % 5], 1);

            end


            // --------------------------------------------------------
            // XOR D[x] into every lane in column x.
            // --------------------------------------------------------
            for (y = 0; y < 5; y++) begin
                for (x = 0; x < 5; x++) begin

                    state[x + 5*y] ^= D[x];

                end
            end



            // ========================================================
            // 2. RHO
            // 3. PI
            //
            // These can conveniently be performed together.
            //
            // Rho:
            //     rotate each lane
            //
            // Pi:
            //     move the rotated lane to another coordinate
            //
            // Mapping:
            //
            //     B[y][(2*x + 3*y) % 5]
            //         =
            //     ROT(A[x][y], r[x][y])
            //
            // ========================================================
            for (x = 0; x < 25; x++)
                B[x] = 64'h0;


            for (y = 0; y < 5; y++) begin
                for (x = 0; x < 5; x++) begin

                    src_idx = x + 5*y;

                    rot = rho_offset(x, y);

                    new_x = y;
                    new_y = (2*x + 3*y) % 5;

                    dst_idx = new_x + 5*new_y;

                    B[dst_idx] =
                        rotl64(state[src_idx], rot);

                end
            end



            // ========================================================
            // 4. CHI
            //
            // Non-linear operation.
            //
            // IMPORTANT:
            //
            // Every new A[x,y] must be calculated from the OLD B row.
            //
            // Do not overwrite B while calculating Chi.
            //
            // ========================================================
            for (y = 0; y < 5; y++) begin
                for (x = 0; x < 5; x++) begin

                    state[x + 5*y] =
                          B[x + 5*y]
                        ^ (
                            (~B[((x + 1) % 5) + 5*y])
                            &
                            B[((x + 2) % 5) + 5*y]
                          );

                end
            end



            // ========================================================
            // 5. IOTA
            //
            // XOR the round constant into A[0][0].
            //
            // Flattened index:
            //
            //     0 + 5*0 = 0
            //
            // ========================================================
            state[0] ^= keccak_round_constant(round);

        end

    endtask



    // ================================================================
    // Absorb one SHA3-384 rate block
    //
    // Input:
    //
    //     block[0:103]
    //
    // SHA3-384 rate:
    //
    //     104 bytes = 13 lanes
    //
    //
    // IMPORTANT:
    //
    // Keccak interprets bytes inside each 64-bit lane as LITTLE ENDIAN.
    //
    // Therefore:
    //
    //     block[0] -> lane[0][7:0]
    //     block[1] -> lane[0][15:8]
    //     ...
    //     block[7] -> lane[0][63:56]
    //
    // This is one of the most common SHA3 implementation bugs.
    // ================================================================
    task automatic sha3_absorb_block(
        inout bit [63:0] state [0:24],
        input byte unsigned block [0:SHA3_384_RATE_BYTES-1]
    );

        int i;

        int lane_idx;
        int byte_idx;

        int shift_amount;

        bit [63:0] tmp;


        for (i = 0; i < SHA3_384_RATE_BYTES; i++) begin

            lane_idx = i / 8;
            byte_idx = i % 8;

            shift_amount = byte_idx * 8;


            // Convert this byte into the correct position
            // inside the 64-bit little-endian lane.
            tmp = 64'(block[i]);

            tmp = tmp << shift_amount;


            // Sponge absorb uses XOR rather than assignment.
            state[lane_idx] ^= tmp;

        end


        // After absorbing one complete rate block,
        // execute Keccak-f[1600].
        keccak_f1600(state);

    endtask



    // ================================================================
    // SHA3-384
    //
    // Usage:
    //
    //     byte unsigned message[];
    //     bit [383:0] digest;
    //
    //     sha3_384(message, digest);
    //
    //
    // If digest is printed as:
    //
    //     $display("%096h", digest);
    //
    // it matches Python:
    //
    //     hashlib.sha3_384(message).hexdigest()
    //
    // ================================================================
    task automatic sha3_384(
        input byte unsigned msg[],
        output bit [383:0] digest
    );

        bit [63:0] state [0:24];

        byte unsigned block [0:SHA3_384_RATE_BYTES-1];

        byte unsigned digest_bytes [0:SHA3_384_DIGEST_BYTES-1];

        int msg_size;

        int offset;
        int remaining;

        int i;

        int lane_idx;
        int byte_idx;

        int shift_amount;


        // ------------------------------------------------------------
        // Initial Keccak sponge state = all zeros.
        // ------------------------------------------------------------
        for (i = 0; i < 25; i++)
            state[i] = 64'h0;


        digest = '0;

        msg_size = msg.size();

        offset = 0;



        // ============================================================
        // Absorb all COMPLETE 104-byte blocks.
        //
        // Example:
        //
        // msg.size() = 250
        //
        // Process:
        //
        //     block #0: byte   0 ~ 103
        //     block #1: byte 104 ~ 207
        //
        // remaining:
        //
        //     byte 208 ~ 249
        //
        // which goes into the final padded block.
        // ============================================================
        while ((msg_size - offset) >= SHA3_384_RATE_BYTES) begin

            for (i = 0; i < SHA3_384_RATE_BYTES; i++)
                block[i] = msg[offset + i];

            sha3_absorb_block(state, block);

            offset += SHA3_384_RATE_BYTES;

        end



        // ============================================================
        // Final block + SHA-3 padding
        //
        // First initialize the block to zero.
        // ============================================================
        for (i = 0; i < SHA3_384_RATE_BYTES; i++)
            block[i] = 8'h00;


        remaining = msg_size - offset;


        // ------------------------------------------------------------
        // Copy remaining message bytes.
        // ------------------------------------------------------------
        for (i = 0; i < remaining; i++)
            block[i] = msg[offset + i];


        // ============================================================
        // SHA-3 padding:
        //
        //     domain separator = 0x06
        //
        // followed by final:
        //
        //     MSB = 1
        //
        // represented by XORing 0x80 into the last rate byte.
        //
        //
        // Therefore:
        //
        //     block[remaining] ^= 0x06
        //     block[103]       ^= 0x80
        //
        //
        // If remaining == 103:
        //
        // both values affect the SAME byte:
        //
        //     0x06 XOR 0x80 = 0x86
        //
        // which is exactly what SHA-3 requires.
        // ============================================================
        block[remaining] ^= 8'h06;

        block[SHA3_384_RATE_BYTES-1] ^= 8'h80;


        // Absorb final padded block.
        sha3_absorb_block(state, block);



        // ============================================================
        // SQUEEZE
        //
        // SHA3-384 only requires 48 output bytes.
        //
        // Rate = 104 bytes.
        //
        // Since:
        //
        //     48 < 104
        //
        // only one squeeze block is required.
        //
        // No additional Keccak permutation is necessary here.
        // ============================================================
        for (i = 0; i < SHA3_384_DIGEST_BYTES; i++) begin

            lane_idx = i / 8;
            byte_idx = i % 8;

            shift_amount = byte_idx * 8;


            // Extract bytes from each lane as little endian.
            digest_bytes[i] =
                (state[lane_idx] >> shift_amount) & 8'hFF;

        end



        // ============================================================
        // Pack bytes into bit[383:0].
        //
        // Python digest:
        //
        //     digest[0]
        //
        // is the first byte displayed by hexdigest().
        //
        // Therefore place:
        //
        //     digest_bytes[0] -> digest[383:376]
        //     digest_bytes[1] -> digest[375:368]
        //     ...
        //
        // This means:
        //
        //     $display("%096h", digest)
        //
        // visually matches Python hexdigest().
        // ============================================================
        for (i = 0; i < SHA3_384_DIGEST_BYTES; i++) begin

            digest[383 - i*8 -: 8] = digest_bytes[i];

        end

    endtask



    // ================================================================
    // SHA3-384 self test
    //
    // Test vectors are compared against known SHA3-384 outputs.
    //
    // Tests:
    //
    //     1. empty message
    //     2. "abc"
    //
    // ================================================================
    task automatic sha3_384_self_test();

        byte unsigned msg[];

        bit [383:0] digest;

        bit [383:0] expected;

        int error_count;


        error_count = 0;


        // ============================================================
        // TEST #1
        //
        // SHA3-384("")
        // ============================================================
        msg = new[0];

        sha3_384(msg, digest);


        expected =
            384'h0c63a75b845e4f7d01107d852e4c2485
                 c51a50aaaa94fc61995e71bbee983a2a
                 c3713831264adb47fb6bd1e058d5f004;


        if (digest !== expected) begin

            $error(
                "[SHA3-384] EMPTY MESSAGE FAILED\n"
                //"Expected = %096h\n"
                //"Actual   = %096h",
                //expected,
                //digest
            );

            $display(
                "[SHA3-384] Expected = %096h",
                expected
            );

            $display(
                "[SHA3-384] Actual   = %096h",
                digest
            );

            error_count++;

        end
        else begin

            $display(
                "[SHA3-384] EMPTY MESSAGE PASS : %096h",
                digest
            );

        end



        // ============================================================
        // TEST #2
        //
        // SHA3-384("abc")
        // ============================================================
        msg = new[3];

        msg[0] = 8'h61;  // a
        msg[1] = 8'h62;  // b
        msg[2] = 8'h63;  // c


        sha3_384(msg, digest);


        expected =
            384'hec01498288516fc926459f58e2c6ad8d
                 f9b473cb0fc08c2596da7cf0e49be4b2
                 98d88cea927ac7f539f1edf228376d25;


        if (digest !== expected) begin

            $error("[SHA3-384] ABC FAILED");

            $display(
                "[SHA3-384] Expected = %096h",
                expected
            );

            $display(
                "[SHA3-384] Actual   = %096h",
                digest
            );

            error_count++;

        end
        else begin

            $display(
                "[SHA3-384] ABC PASS : %096h",
                digest
            );

        end



        // ============================================================
        // Final result
        // ============================================================
        if (error_count == 0) begin

            $display(
                "=============================================="
            );

            $display(
                " SHA3-384 SELF TEST PASS"
            );

            $display(
                "=============================================="
            );

        end
        else begin

            $fatal(
                1,
                "SHA3-384 SELF TEST FAILED: %0d errors",
                error_count
            );

        end

    endtask



endpackage
