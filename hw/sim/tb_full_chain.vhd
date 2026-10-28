library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================================
--  Testbench za CEO acc_image_filter (najverniji test - ceo lanac)
--
--  Instancira tvoj pravi acc_image_filter i:
--   1) Pise konfiguracione registre preko AXI-Lite (kao softver AccConfigure):
--      radius=1, img_w=img_h=8, coeff_scale=4096, svi koeficijenti=3641, MODE0
--      (adrese 4-bajtne: ctrl=0x00, radius=0x04, img_w=0x08, img_h=0x0C,
--       scale=0x10, coeff0=0x14 korak 4)
--   2) Salje sliku 8x8 preko s_axis (kao DMA MM2S): 64 piksela, gradijent
--   3) Glumi DMA S2MM na izlazu (m_axis_tready=1) i broji transfere + TLAST
--
--  Ocekivano: out 6x6=36 piksela; MODE0 -> 18 transfera; TLAST na 18.
--  Koristi TVOJ pravi line_buffer - pravi pokazatelj sta se desava na plocici.
-- ============================================================================

entity top_chain_tb is
end top_chain_tb;

architecture sim of top_chain_tb is

    constant IMG_W : integer := 8;
    constant IMG_H : integer := 8;

    signal s_axi_aclk    : std_logic := '0';
    signal s_axi_aresetn : std_logic := '0';

    -- AXI-Lite
    signal s_axi_awaddr  : std_logic_vector(15 downto 0) := (others => '0');
    signal s_axi_awvalid : std_logic := '0';
    signal s_axi_awready : std_logic;
    signal s_axi_wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axi_wvalid  : std_logic := '0';
    signal s_axi_wready   : std_logic;
    signal s_axi_bresp    : std_logic_vector(1 downto 0);
    signal s_axi_bvalid   : std_logic;
    signal s_axi_bready    : std_logic := '1';
    signal s_axi_araddr   : std_logic_vector(15 downto 0) := (others => '0');
    signal s_axi_arvalid  : std_logic := '0';
    signal s_axi_arready   : std_logic;
    signal s_axi_rdata     : std_logic_vector(31 downto 0);
    signal s_axi_rvalid    : std_logic;
    signal s_axi_rresp     : std_logic_vector(1 downto 0);
    signal s_axi_rready    : std_logic := '1';

    -- AXI-Stream ulaz
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tready : std_logic;
    signal s_axis_tdata  : std_logic_vector(7 downto 0) := (others => '0');

    -- AXI-Stream izlaz
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '1';   -- DMA uvek spreman
    signal m_axis_tdata  : std_logic_vector(15 downto 0);
    signal m_axis_tlast  : std_logic;

    constant CLK_PERIOD : time := 10 ns;

    signal cnt_out_xfer : integer := 0;
    signal cnt_out_last : integer := 0;
    signal last_at_xfer : integer := -1;

    -- Procedura za AXI-Lite upis jednog registra
    procedure axi_write(
        signal clk    : in  std_logic;
        signal awaddr : out std_logic_vector(15 downto 0);
        signal awvalid: out std_logic;
        signal awready: in  std_logic;
        signal wdata  : out std_logic_vector(31 downto 0);
        signal wvalid : out std_logic;
        signal wready : in  std_logic;
        signal bvalid : in  std_logic;
        addr : in integer;
        data : in integer
    ) is
    begin
        wait until rising_edge(clk);
        awaddr  <= std_logic_vector(to_unsigned(addr, 16));
        awvalid <= '1';
        wdata   <= std_logic_vector(to_unsigned(data, 32));
        wvalid  <= '1';
        -- cekaj da slave prihvati adresu i podatak
        wait until rising_edge(clk) and awready = '1' and wready = '1';
        awvalid <= '0';
        wvalid  <= '0';
        -- cekaj bvalid (write response)
        wait until rising_edge(clk) and bvalid = '1';
        wait until rising_edge(clk);
    end procedure;

begin

    dut : entity work.acc_image_filter
        port map (
            s_axi_aclk => s_axi_aclk, s_axi_aresetn => s_axi_aresetn,
            s_axi_awaddr => s_axi_awaddr, s_axi_awvalid => s_axi_awvalid, s_axi_awready => s_axi_awready,
            s_axi_wdata => s_axi_wdata, s_axi_wvalid => s_axi_wvalid, s_axi_wready => s_axi_wready,
            s_axi_bresp => s_axi_bresp, s_axi_bvalid => s_axi_bvalid, s_axi_bready => s_axi_bready,
            s_axi_araddr => s_axi_araddr, s_axi_arvalid => s_axi_arvalid, s_axi_arready => s_axi_arready,
            s_axi_rdata => s_axi_rdata, s_axi_rvalid => s_axi_rvalid, s_axi_rresp => s_axi_rresp, s_axi_rready => s_axi_rready,
            s_axis_tvalid => s_axis_tvalid, s_axis_tready => s_axis_tready, s_axis_tdata => s_axis_tdata,
            m_axis_tvalid => m_axis_tvalid, m_axis_tready => m_axis_tready,
            m_axis_tdata => m_axis_tdata, m_axis_tlast => m_axis_tlast
        );

    clk_proc : process
    begin
        s_axi_aclk <= '0'; wait for CLK_PERIOD/2;
        s_axi_aclk <= '1'; wait for CLK_PERIOD/2;
    end process;

    -- Brojanje izlaznih transfera
    count_proc : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if m_axis_tvalid = '1' and m_axis_tready = '1' then
                cnt_out_xfer <= cnt_out_xfer + 1;
                if m_axis_tlast = '1' then
                    cnt_out_last <= cnt_out_last + 1;
                    last_at_xfer <= cnt_out_xfer + 1;
                end if;
            end if;
        end if;
    end process;

    stim : process
    begin
        -- Reset
        s_axi_aresetn <= '0';
        wait for 10*CLK_PERIOD;
        s_axi_aresetn <= '1';
        wait for 5*CLK_PERIOD;

        -- Upisi registre preko AXI-Lite (4-bajtne adrese)
        axi_write(s_axi_aclk, s_axi_awaddr, s_axi_awvalid, s_axi_awready,
                  s_axi_wdata, s_axi_wvalid, s_axi_wready, s_axi_bvalid, 16#00#, 0);      -- ctrl (MODE0)
        axi_write(s_axi_aclk, s_axi_awaddr, s_axi_awvalid, s_axi_awready,
                  s_axi_wdata, s_axi_wvalid, s_axi_wready, s_axi_bvalid, 16#04#, 1);      -- radius=1
        axi_write(s_axi_aclk, s_axi_awaddr, s_axi_awvalid, s_axi_awready,
                  s_axi_wdata, s_axi_wvalid, s_axi_wready, s_axi_bvalid, 16#08#, IMG_W);  -- img_w
        axi_write(s_axi_aclk, s_axi_awaddr, s_axi_awvalid, s_axi_awready,
                  s_axi_wdata, s_axi_wvalid, s_axi_wready, s_axi_bvalid, 16#0C#, IMG_H);  -- img_h
        axi_write(s_axi_aclk, s_axi_awaddr, s_axi_awvalid, s_axi_awready,
                  s_axi_wdata, s_axi_wvalid, s_axi_wready, s_axi_bvalid, 16#10#, 4096);   -- coeff_scale
        -- koeficijenti W0..W80 = 3641 (adrese 0x14 + 4*i)
        for i in 0 to 80 loop
            axi_write(s_axi_aclk, s_axi_awaddr, s_axi_awvalid, s_axi_awready,
                      s_axi_wdata, s_axi_wvalid, s_axi_wready, s_axi_bvalid, 16#14# + 4*i, 3641);
        end loop;

        wait for 5*CLK_PERIOD;

        -- Posalji sliku 8x8 preko s_axis (64 piksela, gradijent)
        for p in 0 to IMG_W*IMG_H-1 loop
            s_axis_tdata  <= std_logic_vector(to_unsigned(p mod 256, 8));
            s_axis_tvalid <= '1';
            -- cekaj handshake (tready)
            wait until rising_edge(s_axi_aclk) and s_axis_tready = '1';
        end loop;
        s_axis_tvalid <= '0';

        -- Sacekaj da lanac zavrsi obradu (pipeline + izlaz)
        wait for 200*CLK_PERIOD;

        report "=== REZULTAT (CEO LANAC) ===" severity note;
        report "Broj m_axis transfera:     " & integer'image(cnt_out_xfer) severity note;
        report "Ocekivano (18):            18" severity note;
        report "Broj m_axis_tlast pulseva: " & integer'image(cnt_out_last) severity note;
        report "TLAST dosao na transferu:  " & integer'image(last_at_xfer) severity note;

        if cnt_out_xfer = 0 then
            report ">>> PROBLEM: nista ne izlazi na m_axis! <<<" severity warning;
        elsif cnt_out_last = 0 then
            report ">>> PROBLEM: m_axis_tlast se NIKAD ne dize! <<<" severity warning;
        elsif cnt_out_last = 1 and last_at_xfer = cnt_out_xfer then
            report ">>> OK: sve radi - TLAST na poslednjem transferu <<<" severity note;
        else
            report ">>> PROBLEM: TLAST na pogresnom mestu ili vise puta <<<" severity warning;
        end if;

        wait;
    end process;

end sim;