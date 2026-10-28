-------------------------------------------------------------------------------
--  tb_acc_image_filter_top.vhd   (VHDL-93 kompatibilno - bez 2008 konstrukta)
--
--  TOP-LEVEL testbench za ceo acc_image_filter:
--    - upisuje registre preko AXI4-Lite (radius=1, img 8x8, MODE 0, box 1/9)
--    - gura 8x8 sliku (gradient) kroz s_axis
--    - drzi m_axis_tready = '1' (kao naoruzan DMA) i PRATI m_axis
--    - broji izlazne reci + hvata tlast
--
--  Cilj: videti da li m_axis_tvalid UOPSTE opali. Ako ne opali ovde,
--  bug je u RTL-u (a ne na ploci) i lovi se odavde.
--
--  Ocekivano za 8x8, radius 1, MODE 0:
--    OUT = 6x6 = 36 piksela -> pakuje 2/rec -> 18 reci, poslednja sa TLAST.
--
--  NAPOMENA: ne koristi to_hstring ni std.env.stop (rade tek u VHDL-2008).
--  Ispis tdata je decimalni. Simulacija se zaustavlja namernim
--  'assert false ... severity failure' na kraju (nije prava greska).
-------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_acc_image_filter_top is
end tb_acc_image_filter_top;

architecture sim of tb_acc_image_filter_top is

    constant CLK_P : time := 10 ns;

    signal aclk    : std_logic := '0';
    signal aresetn : std_logic := '0';

    -- AXI-Lite
    signal awaddr  : std_logic_vector(15 downto 0) := (others => '0');
    signal awvalid : std_logic := '0';
    signal awready : std_logic;
    signal wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal wvalid  : std_logic := '0';
    signal wready  : std_logic;
    signal bresp   : std_logic_vector(1 downto 0);
    signal bvalid  : std_logic;
    signal bready  : std_logic := '0';
    signal araddr  : std_logic_vector(15 downto 0) := (others => '0');
    signal arvalid : std_logic := '0';
    signal arready : std_logic;
    signal rdata   : std_logic_vector(31 downto 0);
    signal rvalid  : std_logic;
    signal rresp   : std_logic_vector(1 downto 0);
    signal rready  : std_logic := '0';

    -- Stream ulaz
    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');

    -- Stream izlaz
    signal m_tvalid : std_logic;
    signal m_tready : std_logic := '1';   -- DMA uvek spreman
    signal m_tdata  : std_logic_vector(15 downto 0);
    signal m_tlast  : std_logic;

    -- test parametri
    constant IMG_W  : integer := 8;
    constant IMG_H  : integer := 8;
    constant RADIUS : integer := 1;

    signal out_words : integer := 0;
    signal got_tlast : boolean := false;

    -- AXI-Lite upis (4-bajtni offset)
    procedure axi_write(
        constant addr : in std_logic_vector(15 downto 0);
        constant data : in std_logic_vector(31 downto 0);
        signal clk       : in  std_logic;
        signal s_awaddr  : out std_logic_vector(15 downto 0);
        signal s_awvalid : out std_logic;
        signal s_wdata   : out std_logic_vector(31 downto 0);
        signal s_wvalid  : out std_logic;
        signal s_bready  : out std_logic;
        signal s_bvalid  : in  std_logic
    ) is
    begin
        wait until rising_edge(clk);
        s_awaddr  <= addr;
        s_awvalid <= '1';
        s_wdata   <= data;
        s_wvalid  <= '1';
        s_bready  <= '1';
        wait until rising_edge(clk) and s_bvalid = '1';
        wait until rising_edge(clk);
        s_awvalid <= '0';
        s_wvalid  <= '0';
        s_bready  <= '0';
        wait until rising_edge(clk);
    end procedure;

begin

    -- DUT
    dut : entity work.acc_image_filter
    port map (
        s_axi_aclk => aclk, s_axi_aresetn => aresetn,
        s_axi_awaddr => awaddr, s_axi_awvalid => awvalid, s_axi_awready => awready,
        s_axi_wdata => wdata,  s_axi_wvalid => wvalid,  s_axi_wready => wready,
        s_axi_bresp => bresp,  s_axi_bvalid => bvalid,  s_axi_bready => bready,
        s_axi_araddr => araddr, s_axi_arvalid => arvalid, s_axi_arready => arready,
        s_axi_rdata => rdata,  s_axi_rvalid => rvalid,  s_axi_rresp => rresp, s_axi_rready => rready,
        s_axis_tvalid => s_tvalid, s_axis_tready => s_tready, s_axis_tdata => s_tdata,
        m_axis_tvalid => m_tvalid, m_axis_tready => m_tready, m_axis_tdata => m_tdata,
        m_axis_tlast => m_tlast
    );

    -- takt
    aclk <= not aclk after CLK_P/2;

    -- MONITOR izlaza: broji reci, hvata tlast (bez to_hstring)
    monitor : process(aclk)
    begin
        if rising_edge(aclk) then
            if m_tvalid = '1' and m_tready = '1' then
                out_words <= out_words + 1;
                report "IZLAZ rec #" & integer'image(out_words) &
                       "  tdata=" & integer'image(to_integer(unsigned(m_tdata))) &
                       "  tlast=" & std_logic'image(m_tlast);
                if m_tlast = '1' then
                    got_tlast <= true;
                end if;
            end if;
        end if;
    end process;

    -- glavni stimulus
    stim : process
        variable i, r, c, grow, gcol, idx : integer;
    begin
        -- reset
        aresetn <= '0';
        wait for 100 ns;
        wait until rising_edge(aclk);
        aresetn <= '1';
        wait until rising_edge(aclk);

        -- ---- Konfiguracija registara (4-bajtni offseti) ----
        axi_write(x"0000", x"00000000", aclk, awaddr, awvalid, wdata, wvalid, bready, bvalid); -- ctrl=0 (MODE0)
        axi_write(x"0004", x"00000001", aclk, awaddr, awvalid, wdata, wvalid, bready, bvalid); -- radius=1
        axi_write(x"0008", std_logic_vector(to_unsigned(IMG_W,32)), aclk, awaddr, awvalid, wdata, wvalid, bready, bvalid);
        axi_write(x"000C", std_logic_vector(to_unsigned(IMG_H,32)), aclk, awaddr, awvalid, wdata, wvalid, bready, bvalid);
        axi_write(x"0010", x"00001000", aclk, awaddr, awvalid, wdata, wvalid, bready, bvalid); -- scale=1.0

        -- centralni 3x3 blok = 1/9 (0x0E39), ostalo 0
        for r in 0 to 2 loop
            for c in 0 to 2 loop
                grow := (4 - RADIUS) + r;
                gcol := (4 - RADIUS) + c;
                idx  := grow*9 + gcol;                       -- 0..80
                axi_write(std_logic_vector(to_unsigned(16#14# + 4*idx, 16)),
                          x"00000E39", aclk, awaddr, awvalid, wdata, wvalid, bready, bvalid);
            end loop;
        end loop;

        report "=== Registri upisani, krecem stream ===";

        -- ---- Stream: 8x8 gradient ----
        for i in 0 to IMG_W*IMG_H - 1 loop
            wait until rising_edge(aclk);
            s_tvalid <= '1';
            s_tdata  <= std_logic_vector(to_unsigned(i mod 256, 8));
            wait until rising_edge(aclk) and s_tready = '1';
        end loop;
        wait until rising_edge(aclk);
        s_tvalid <= '0';

        report "=== Stream zavrsen, cekam izlaz ===";

        -- daj vremena da se pipeline izprazni i izlaz zavrsi
        wait for 5 us;

        -- ---- Rezultat ----
        report "==================================================";
        report "UKUPNO izlaznih reci: " & integer'image(out_words);
        report "OCEKIVANO (8x8,R1,MODE0): 18 reci";
        if out_words = 0 then
            report "!!! NULA IZLAZA - akcelerator NE emituje ni u simulaciji => RTL BUG" severity warning;
        elsif got_tlast then
            report ">>> IZLAZ RADI i TLAST je stigao. RTL je OK => problem je HARDVER/pakovanje." severity warning;
        else
            report "!!! Ima izlaza ali NEMA TLAST => bug u tlast/broju piksela" severity warning;
        end if;
        report "==================================================";

        -- zaustavi simulaciju bez std.env (namerni failure koji zaustavlja run)
        assert false report "KRAJ SIMULACIJE (namerni stop, nije greska)" severity failure;
        wait;
    end process;

end sim;