library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_axis_input_handler is
-- Testbench nema portove
end tb_axis_input_handler;

architecture Behavioral of tb_axis_input_handler is

    -- Signali za povezivanje sa modulom
    signal aclk         : std_logic := '0';
    signal aresetn      : std_logic := '0';
    signal s_axis_tvalid: std_logic := '0';
    signal s_axis_tready: std_logic;
    signal s_axis_tdata : std_logic_vector(7 downto 0) := (others => '0');
    signal data_out     : std_logic_vector(7 downto 0);
    signal data_valid   : std_logic;

    -- Konstanta za takt (100 MHz)
    constant CLK_PERIOD : time := 10 ns;

begin

    -- Instanciranje tvog modula (DUT)
    uut: entity work.axis_input_handler
        port map (
            aclk         => aclk,
            aresetn      => aresetn,
            s_axis_tvalid=> s_axis_tvalid,
            s_axis_tready=> s_axis_tready,
            s_axis_tdata => s_axis_tdata,
            data_out     => data_out,
            data_valid   => data_valid
        );

    -- Proces za generisanje takta
    clk_process: process
    begin
        aclk <= '0';
        wait for CLK_PERIOD / 2;
        aclk <= '1';
        wait for CLK_PERIOD / 2;
    end process;

    -- Proces za stimulaciju (Simulacija DMA-ja)
    stim_process: process
    begin
        -- 1. Resetuj modul
        report "---- Pokrecem reset ----";
        aresetn <= '0';
        wait for 100 ns;
        aresetn <= '1';
        wait for 20 ns;
        
        report "---- Krenulo testiranje ----";

        -- 2. Pošalji prvi piksel (0xAA)
        report "Saljem piksel 0xAA";
        s_axis_tdata <= x"AA";
        s_axis_tvalid <= '1';          -- DMA signalizira da ima podatak
        wait for CLK_PERIOD;           -- Sačekaj jedan takt
        s_axis_tvalid <= '0';          -- Spusti valid nakon što je modul primio
        wait for 20 ns;                -- Mala pauza

        -- 3. Pošalji drugi piksel (0xBB)
        report "Saljem piksel 0xBB";
        s_axis_tdata <= x"BB";
        s_axis_tvalid <= '1';
        wait for CLK_PERIOD;
        s_axis_tvalid <= '0';
        wait for 20 ns;

        -- 4. Pauza (simuliramo da DMA nema podataka)
        report "Pauza (DMA nema sta da salje)";
        s_axis_tvalid <= '0';
        wait for 40 ns;

        -- 5. Pošalji treći piksel (0xCC)
        report "Saljem piksel 0xCC";
        s_axis_tdata <= x"CC";
        s_axis_tvalid <= '1';
        wait for CLK_PERIOD;
        s_axis_tvalid <= '0';
        wait for 20 ns;

        report "---- Svi testovi zavrseni! ----";
        wait; -- Kraj simulacije
    end process;

end Behavioral;