library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================
-- Testbench za line_buffer
--   Slika 6x6, radius = 1 (susedstvo 3x3, treba 2 reda istorije).
--   Pikseli se guraju redom (row-major): vrednost piksela = red*10 + kolona,
--   da bi u simulaciji lako prepoznao odakle koji bajt dolazi.
--
--   Sta gledas u talasnim oblicima (Wave):
--     * column_out (72 bita) - donji bajt [7:0] je NAJNOVIJI red,
--       iznad idu stariji redovi. Za radius 1 tebi su bitna donja 3 bajta:
--       [7:0]  = tekuci red
--       [15:8] = red iznad
--       [23:16]= red iznad toga
--     * column_valid - kada je '1', kolona je spremna za ALU.
--       Za radius 1 i 6x6 sliku, prvi validni izlaz stize tek kad
--       stigne treci red (row_count = 2), i to od trece kolone nadalje.
-- ============================================================

entity tb_line_buffer is
end tb_line_buffer;

architecture sim of tb_line_buffer is

    constant IMG_W : integer := 6;
    constant IMG_H : integer := 6;

    signal aclk        : std_logic := '0';
    signal aresetn     : std_logic := '0';

    signal pixel_in    : std_logic_vector(7 downto 0) := (others => '0');
    signal pixel_valid : std_logic := '0';
    signal reg_radius  : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(1, 16));
    signal reg_img_w   : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(IMG_W, 16));
    signal reg_img_h   : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(IMG_H, 16));
    signal next_ready  : std_logic;

    signal column_out   : std_logic_vector(71 downto 0);
    signal column_valid : std_logic;
    signal column_en    : std_logic;
    signal row_start    : std_logic;

    signal alu_ready    : std_logic := '1';   -- ALU je uvek spreman

    constant CLK_PERIOD : time := 10 ns;
    signal sim_done : boolean := false;

begin

    ------------------------------------------------------------
    -- DUT
    ------------------------------------------------------------
    dut : entity work.line_buffer
        generic map (C_MAX_IMG_WIDTH => 512)
        port map (
            aclk         => aclk,
            aresetn      => aresetn,
            pixel_in     => pixel_in,
            pixel_valid  => pixel_valid,
            reg_radius   => reg_radius,
            reg_img_w    => reg_img_w,
            reg_img_h    => reg_img_h,
            next_ready   => next_ready,
            column_out   => column_out,
            column_valid => column_valid,
            column_en    => column_en,
            row_start    => row_start,
            alu_ready    => alu_ready
        );

    ------------------------------------------------------------
    -- Clock
    ------------------------------------------------------------
    clk_gen : process
    begin
        while not sim_done loop
            aclk <= '0';
            wait for CLK_PERIOD/2;
            aclk <= '1';
            wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    ------------------------------------------------------------
    -- Stimulus: guraj piksele row-major, vrednost = red*10 + kolona
    ------------------------------------------------------------
    stim : process
        procedure send_pixel(val : integer) is
        begin
            pixel_in    <= std_logic_vector(to_unsigned(val, 8));
            pixel_valid <= '1';
            wait until rising_edge(aclk);
        end procedure;
    begin
        -- reset
        aresetn     <= '0';
        pixel_valid <= '0';
        wait for 4*CLK_PERIOD;
        wait until rising_edge(aclk);
        aresetn <= '1';
        wait until rising_edge(aclk);

        -- posalji celu 6x6 sliku: vrednost = r*10 + c
        for r in 0 to IMG_H-1 loop
            for c in 0 to IMG_W-1 loop
                send_pixel(r*10 + c);
            end loop;
        end loop;

        -- prestani da saljes
        pixel_valid <= '0';
        pixel_in    <= (others => '0');

        -- pusti jos malo taktova da izadje poslednja kolona
        for i in 0 to 10 loop
            wait until rising_edge(aclk);
        end loop;

        sim_done <= true;
        wait;
    end process;

    ------------------------------------------------------------
    -- Monitor: ispisi svaki put kad je column_valid = '1'
    -- (donja 3 bajta su relevantna za radius 1)
    ------------------------------------------------------------
    mon : process
        variable b0, b1, b2 : integer;
    begin
        wait until rising_edge(aclk);
        if column_valid = '1' then
            b0 := to_integer(unsigned(column_out(7 downto 0)));    -- tekuci red
            b1 := to_integer(unsigned(column_out(15 downto 8)));   -- red iznad
            b2 := to_integer(unsigned(column_out(23 downto 16)));  -- red iznad toga
            report "VALID column: donji=" & integer'image(b0) &
                   "  srednji=" & integer'image(b1) &
                   "  gornji="  & integer'image(b2);
        end if;
    end process;

end sim;