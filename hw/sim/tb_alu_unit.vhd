library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================================
--  Testbench za alu_unit
--  Cilj: proveriti da li ALU generise result_last (TLAST) na kraju obrade,
--        i koliko puta se result_valid / result_last dizu.
--
--  Simuliramo manju sliku da simulacija bude brza: img 8x8, radius 1.
--  Ocekivano: out = 6x6 = 36 izlaznih piksela; result_last 1 put na kraju.
--  (Manja slika = brza simulacija, ista logika kao 128x128.)
--
--  Testbench "glumi" line_buffer: salje kolone (72 bita) sa column_valid/
--  column_en/row_start, red po red. Za svaki red salje img_w kolona.
-- ============================================================================

entity alu_unit_tb is
end alu_unit_tb;

architecture sim of alu_unit_tb is

    -- Parametri test-slike (mala, da simulacija bude brza)
    constant IMG_W : integer := 8;
    constant IMG_H : integer := 8;
    constant RAD   : integer := 1;

    signal aclk            : std_logic := '0';
    signal aresetn         : std_logic := '0';
    signal column_in       : std_logic_vector(71 downto 0) := (others => '0');
    signal column_valid    : std_logic := '0';
    signal row_start       : std_logic := '0';
    signal reg_radius      : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_coeff_scale : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_ctrl        : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_img_w       : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_img_h       : std_logic_vector(15 downto 0) := (others => '0');
    signal result_ready    : std_logic := '1';
    signal coeffs_w        : std_logic_vector(1295 downto 0) := (others => '0');
    signal column_en       : std_logic := '0';
    signal alu_ready       : std_logic;
    signal result_out      : std_logic_vector(15 downto 0);
    signal result_valid    : std_logic;
    signal result_last     : std_logic;

    constant CLK_PERIOD : time := 10 ns;

    -- brojaci za proveru
    signal cnt_valid : integer := 0;
    signal cnt_last  : integer := 0;

begin

    -- Instanca DUT (device under test)
    dut : entity work.alu_unit
        port map (
            aclk            => aclk,
            aresetn         => aresetn,
            column_in       => column_in,
            column_valid    => column_valid,
            row_start       => row_start,
            reg_radius      => reg_radius,
            reg_coeff_scale => reg_coeff_scale,
            reg_ctrl        => reg_ctrl,
            reg_img_w       => reg_img_w,
            reg_img_h       => reg_img_h,
            result_ready    => result_ready,
            coeffs_w        => coeffs_w,
            column_en       => column_en,
            alu_ready       => alu_ready,
            result_out      => result_out,
            result_valid    => result_valid,
            result_last     => result_last
        );

    -- Clock
    clk_proc : process
    begin
        aclk <= '0';
        wait for CLK_PERIOD/2;
        aclk <= '1';
        wait for CLK_PERIOD/2;
    end process;

    -- Brojanje result_valid i result_last (za proveru)
    count_proc : process(aclk)
    begin
        if rising_edge(aclk) then
            if result_valid = '1' then
                cnt_valid <= cnt_valid + 1;
            end if;
            if result_last = '1' then
                cnt_last <= cnt_last + 1;
            end if;
        end if;
    end process;

    -- Glavni stimulus
    stim : process
        variable col : std_logic_vector(71 downto 0);
    begin
        -- Postavi parametre (kao sto softver upisuje)
        reg_radius      <= std_logic_vector(to_unsigned(RAD, 16));
        reg_img_w       <= std_logic_vector(to_unsigned(IMG_W, 16));
        reg_img_h       <= std_logic_vector(to_unsigned(IMG_H, 16));
        reg_coeff_scale <= std_logic_vector(to_unsigned(4096, 16));  -- 1.0
        reg_ctrl        <= (others => '0');  -- MODE 0

        -- Box filter: svih 81 koeficijenata = 3641
        for i in 0 to 80 loop
            coeffs_w((i+1)*16-1 downto i*16) <= std_logic_vector(to_unsigned(3641, 16));
        end loop;

        -- Reset
        aresetn <= '0';
        column_en <= '0';
        column_valid <= '0';
        row_start <= '0';
        wait for 5*CLK_PERIOD;
        aresetn <= '1';
        wait for 2*CLK_PERIOD;

        -- Salji kolone: za svaki red (IMG_H redova) salji IMG_W kolona.
        -- Svaka kolona je 72 bita = 9 bajtova. Napunimo je test vrednostima.
        -- column_valid = '1' kad je red "spreman" (za radius 1, od reda 2 na dalje).
        -- Ovde pojednostavljeno: column_valid = '1' za sve kolone od reda >= 2*RAD.

        for r in 0 to IMG_H-1 loop
            for c in 0 to IMG_W-1 loop
                -- napravi test kolonu: svih 9 bajtova = (r*IMG_W + c) mod 256
                col := (others => '0');
                for b in 0 to 8 loop
                    col((b+1)*8-1 downto b*8) := std_logic_vector(to_unsigned((r*IMG_W + c) mod 256, 8));
                end loop;

                column_in <= col;
                column_en <= '1';

                -- row_start na prvoj koloni svakog reda
                if c = 0 then
                    row_start <= '1';
                else
                    row_start <= '0';
                end if;

                -- column_valid: red je vertikalno spreman kad r >= 2*RAD
                if r >= 2*RAD then
                    column_valid <= '1';
                else
                    column_valid <= '0';
                end if;

                wait for CLK_PERIOD;
            end loop;
        end loop;

        -- Zavrsi slanje
        column_en    <= '0';
        column_valid <= '0';
        row_start    <= '0';

        -- Sacekaj da pipeline istekne
        wait for 20*CLK_PERIOD;

        -- Ispisi rezultate provere
        report "=== REZULTAT SIMULACIJE ===" severity note;
        report "Broj result_valid pulseva: " & integer'image(cnt_valid) severity note;
        report "Broj result_last pulseva:  " & integer'image(cnt_last) severity note;
        report "Ocekivano validnih (6x6):  " & integer'image((IMG_W-2*RAD)*(IMG_H-2*RAD)) severity note;

        if cnt_last = 0 then
            report ">>> PROBLEM: result_last se NIKAD ne dize! <<<" severity warning;
        elsif cnt_last = 1 then
            report ">>> OK: result_last se digao tacno 1 put <<<" severity note;
        else
            report ">>> PROBLEM: result_last se digao vise puta! <<<" severity warning;
        end if;

        wait;  -- kraj
    end process;

end sim;