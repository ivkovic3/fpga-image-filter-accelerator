library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_pokusaj is
-- Testbench nema portove (prazno je)
end tb_pokusaj;

architecture Behavioral of tb_pokusaj is

    -- 1. Deklaracija signala za povezivanje sa tvojim modulom
    signal s_axi_aclk    : std_logic := '0';
    signal s_axi_aresetn : std_logic := '0';
    
    -- AXI-Lite Write signali
    signal s_axi_awaddr  : std_logic_vector(15 downto 0) := (others => '0');
    signal s_axi_awvalid : std_logic := '0';
    signal s_axi_awready : std_logic;
    signal s_axi_wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axi_wvalid  : std_logic := '0';
    signal s_axi_wready  : std_logic;
    signal s_axi_bresp   : std_logic_vector(1 downto 0);
    signal s_axi_bvalid  : std_logic;
    signal s_axi_bready  : std_logic := '0';

    -- AXI-Lite Read signali (postoje ali ih ne testiramo, samo ih povezujemo da ne baca greške)
    signal s_axi_araddr  : std_logic_vector(15 downto 0) := (others => '0');
    signal s_axi_arvalid : std_logic := '0';
    signal s_axi_arready : std_logic;
    signal s_axi_rdata   : std_logic_vector(31 downto 0);
    signal s_axi_rvalid  : std_logic;
    signal s_axi_rresp   : std_logic_vector(1 downto 0);
    signal s_axi_rready  : std_logic := '0';

    -- AXI-Stream signali (postoje ali ih ne koristimo u ovom testu, samo povezujemo)
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tready : std_logic;
    signal s_axis_tdata  : std_logic_vector(7 downto 0) := (others => '0');
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '0';
    signal m_axis_tdata  : std_logic_vector(15 downto 0);

    -- Konstanta za takt (100 MHz)
    constant CLK_PERIOD : time := 10 ns;

    -- 2. Procedura za AXI-Lite Pisanje (da ne kucamo ruke svaki put)
    procedure axi_write(
        addr : in std_logic_vector(15 downto 0);
        data : in std_logic_vector(31 downto 0);
        signal awaddr  : out std_logic_vector(15 downto 0);
        signal awvalid : out std_logic;
        signal wdata   : out std_logic_vector(31 downto 0);
        signal wvalid  : out std_logic;
        signal bready  : out std_logic;
        signal awready : in  std_logic;
        signal wready  : in  std_logic;
        signal bvalid  : in  std_logic
    ) is
    begin
        -- Postavi adresu i podatak
        awaddr  <= addr;
        awvalid <= '1';
        wdata   <= data;
        wvalid  <= '1';
        
        -- Čekaj da modul potvrdi da je spreman (AWREADY i WREADY)
        wait until rising_edge(s_axi_aclk) and (awready = '1') and (wready = '1');
        
        -- Spusti signale
        awvalid <= '0';
        wvalid  <= '0';
        
        -- Čekaj da modul pošalje BVALID (potvrda upisa)
        wait until rising_edge(s_axi_aclk) and (bvalid = '1');
        
        -- Odgovori sa BREADY
        bready <= '1';
        wait for CLK_PERIOD;
        bready <= '0';
    end procedure;

begin

    -- 3. Instanciranje tvog modula
    uut: entity work.pokusaj
        port map (
            s_axi_aclk    => s_axi_aclk,
            s_axi_aresetn => s_axi_aresetn,
            s_axi_awaddr  => s_axi_awaddr,
            s_axi_awvalid => s_axi_awvalid,
            s_axi_awready => s_axi_awready,
            s_axi_wdata   => s_axi_wdata,
            s_axi_wvalid  => s_axi_wvalid,
            s_axi_wready  => s_axi_wready,
            s_axi_bresp   => s_axi_bresp,
            s_axi_bvalid  => s_axi_bvalid,
            s_axi_bready  => s_axi_bready,
            s_axi_araddr  => s_axi_araddr,
            s_axi_arvalid => s_axi_arvalid,
            s_axi_arready => s_axi_arready,
            s_axi_rdata   => s_axi_rdata,
            s_axi_rvalid  => s_axi_rvalid,
            s_axi_rresp   => s_axi_rresp,
            s_axi_rready  => s_axi_rready,
            s_axi_tvalid  => s_axis_tvalid,
            s_axi_tready  => s_axis_tready,
            s_axi_tdata   => s_axis_tdata,
            m_axi_tvalid  => m_axis_tvalid,
            m_axi_tready  => m_axis_tready,
            m_axi_tdata   => m_axis_tdata
        );

    -- 4. Generisanje takta
    clk_process: process
    begin
        s_axi_aclk <= '0';
        wait for CLK_PERIOD / 2;
        s_axi_aclk <= '1';
        wait for CLK_PERIOD / 2;
    end process;

    -- 5. Glavni proces za testiranje (Stimulus)
    stim_process: process
    begin
        -- 5.1 Reset stanje
        s_axi_aresetn <= '0';
        wait for 100 ns;
        s_axi_aresetn <= '1';
        wait for 50 ns;
        
        report "---- Krenuo testiranje ----";

        -- TEST 1: Upis u kontrolni registar (ADDR 0x00, DATA 0x0000_1234)
        report "Upisujem u reg_ctrl (0x00): 0x1234";
        axi_write(x"0000", x"00001234", s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid, s_axi_bready, s_axi_awready, s_axi_wready, s_axi_bvalid);
        wait for 50 ns;

        -- TEST 2: Upis u širinu slike (ADDR 0x04, DATA 0x0000_0555)
        report "Upisujem u reg_img_w (0x04): 0x0555";
        axi_write(x"0004", x"00000555", s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid, s_axi_bready, s_axi_awready, s_axi_wready, s_axi_bvalid);
        wait for 50 ns;

        -- TEST 3: Upis prvog koeficijenta (ADDR 0x10, DATA 0x0000_AAAA) -> treba da pogodi coeff_regs(0)
        report "Upisujem prvi koeficijent (0x10): 0xAAAA";
        axi_write(x"000A", x"0000AAAA", s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid, s_axi_bready, s_axi_awready, s_axi_wready, s_axi_bvalid);
        wait for 50 ns;

        -- TEST 4: Upis drugog koeficijenta (ADDR 0x12, DATA 0x0000_BBBB) -> treba da pogodi coeff_regs(1)
        report "Upisujem drugi koeficijent (0x12): 0xBBBB";
        axi_write(x"000C", x"0000BBBB", s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid, s_axi_bready, s_axi_awready, s_axi_wready, s_axi_bvalid);
        wait for 50 ns;

        -- TEST 5: Upis na adresu van opsega (ADDR 0x0200, DATA 0xFFFF) -> OVO TREBA DA SE IGNORIŠE
        report "Upisujem van opsega (0x0200, treba da bude ignorisano)";
        axi_write(x"0200", x"0000FFFF", s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid, s_axi_bready, s_axi_awready, s_axi_wready, s_axi_bvalid);
        
        report "---- Svi testovi zavrseni! ----";
        wait; -- Beskonačno čekanje (kraj simulacije)
    end process;

end Behavioral;