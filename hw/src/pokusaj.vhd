library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;


--  AXI4-Lite registarski modul akceleratora
--    - ADDR_LSB dekodiranje (registri rec-adresirani, 4-bajtni razmak)
--    - write/read state masine (WriteAddress/WriteData/WriteStalled,
--      ReadAddress/ReadData) - proveren handshake
--  SOFTVER: koristi Xil_Out32/Xil_In32 na 4-bajtnim offsetima
--           (ctrl=0x00, radius=0x04, ..., coeff0=0x14, korak 4).


entity pokusaj is
    Port (
        s_axi_aclk    : in  STD_LOGIC;
        s_axi_aresetn : in  STD_LOGIC;

        s_axi_awaddr  : in  STD_LOGIC_VECTOR (15 downto 0);
        s_axi_awvalid : in  STD_LOGIC;
        s_axi_awready : out STD_LOGIC;
        s_axi_wdata   : in  STD_LOGIC_VECTOR (31 downto 0);
        s_axi_wvalid  : in  STD_LOGIC;
        s_axi_wready  : out STD_LOGIC;
        s_axi_bresp   : out STD_LOGIC_VECTOR (1 downto 0);
        s_axi_bvalid  : out STD_LOGIC;
        s_axi_bready  : in  STD_LOGIC;
        s_axi_araddr  : in  STD_LOGIC_VECTOR (15 downto 0);
        s_axi_arvalid : in  STD_LOGIC;
        s_axi_arready : out STD_LOGIC;
        s_axi_rdata   : out STD_LOGIC_VECTOR (31 downto 0);
        s_axi_rvalid  : out STD_LOGIC;
        s_axi_rresp   : out STD_LOGIC_VECTOR (1 downto 0);
        s_axi_rready  : in  STD_LOGIC;

        reg_ctrl_out        : out std_logic_vector(15 downto 0);
        reg_radius_out      : out std_logic_vector(15 downto 0);
        reg_img_w_out       : out std_logic_vector(15 downto 0);
        reg_img_h_out       : out std_logic_vector(15 downto 0);
        reg_coeff_scale_out : out std_logic_vector(15 downto 0);
        coeff_w_out         : out std_logic_vector(1295 downto 0)
    );
end pokusaj;

architecture Behavioral of pokusaj is

    constant REG_IDX_W : natural := 7;   -- 86 registara -> 7 bitova indeksa
    constant ADDR_LSB  : natural := 2;   -- donja 2 bita = bajt-offset, ne koriste se

    constant IDX_CTRL        : natural := 0;
    constant IDX_RADIUS      : natural := 1;
    constant IDX_IMG_W       : natural := 2;
    constant IDX_IMG_H       : natural := 3;
    constant IDX_COEFF_SCALE : natural := 4;
    constant IDX_COEFF0      : natural := 5;
    constant IDX_COEFF80     : natural := 85;

    signal reg_ctrl        : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_radius      : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_img_w       : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_img_h       : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_coeff_scale : std_logic_vector(15 downto 0) := (others => '0');

    type coeff_array is array (0 to 80) of std_logic_vector(15 downto 0);
    signal coeff_regs : coeff_array := (others => (others => '0'));

    signal axi_awready : std_logic := '0';
    signal axi_wready  : std_logic := '0';
    signal axi_awaddr  : std_logic_vector(15 downto 0) := (others => '0');
    signal axi_bvalid  : std_logic := '0';

    signal axi_arready : std_logic := '0';
    signal axi_rvalid  : std_logic := '0';
    signal axi_araddr  : std_logic_vector(15 downto 0) := (others => '0');

    signal reg_waddr : std_logic_vector(REG_IDX_W-1 downto 0);
    signal reg_raddr : std_logic_vector(REG_IDX_W-1 downto 0);

    signal axi_write_ready : std_logic;
    signal rdata_i : std_logic_vector(31 downto 0) := (others => '0');

    type fsm_read_state_type  is (ReadAddress,  ReadData);
    type fsm_write_state_type is (WriteAddress, WriteData, WriteStalled);
    signal fsm_axi_read_state  : fsm_read_state_type  := ReadAddress;
    signal fsm_axi_write_state : fsm_write_state_type := WriteAddress;

begin

    reg_waddr <= s_axi_awaddr(REG_IDX_W-1+ADDR_LSB downto ADDR_LSB) when (s_axi_awvalid = '1')
                 else axi_awaddr(REG_IDX_W-1+ADDR_LSB downto ADDR_LSB);

    reg_raddr <= s_axi_araddr(REG_IDX_W-1+ADDR_LSB downto ADDR_LSB) when (s_axi_arvalid = '1')
                 else axi_araddr(REG_IDX_W-1+ADDR_LSB downto ADDR_LSB);

    -- WRITE registri
    write_regs : process (s_axi_aclk) is
        variable idx : integer range 0 to 127;
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                reg_ctrl        <= (others => '0');
                reg_radius      <= (others => '0');
                reg_img_w       <= (others => '0');
                reg_img_h       <= (others => '0');
                reg_coeff_scale <= (others => '0');
                for i in 0 to 80 loop
                    coeff_regs(i) <= (others => '0');
                end loop;
            else
                if axi_write_ready = '1' then
                    idx := to_integer(unsigned(reg_waddr));
                    case idx is
                        when IDX_CTRL        => reg_ctrl        <= s_axi_wdata(15 downto 0);
                        when IDX_RADIUS      => reg_radius      <= s_axi_wdata(15 downto 0);
                        when IDX_IMG_W       => reg_img_w       <= s_axi_wdata(15 downto 0);
                        when IDX_IMG_H       => reg_img_h       <= s_axi_wdata(15 downto 0);
                        when IDX_COEFF_SCALE => reg_coeff_scale <= s_axi_wdata(15 downto 0);
                        when others =>
                            if (idx >= IDX_COEFF0) and (idx <= IDX_COEFF80) then
                                coeff_regs(idx - IDX_COEFF0) <= s_axi_wdata(15 downto 0);
                            end if;
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- READ mux
    read_mux : process (reg_raddr, reg_ctrl, reg_radius, reg_img_w, reg_img_h,
                        reg_coeff_scale, coeff_regs) is
        variable idx : integer range 0 to 127;
    begin
        idx := to_integer(unsigned(reg_raddr));
        rdata_i <= (others => '0');
        case idx is
            when IDX_CTRL        => rdata_i <= x"0000" & reg_ctrl;
            when IDX_RADIUS      => rdata_i <= x"0000" & reg_radius;
            when IDX_IMG_W       => rdata_i <= x"0000" & reg_img_w;
            when IDX_IMG_H       => rdata_i <= x"0000" & reg_img_h;
            when IDX_COEFF_SCALE => rdata_i <= x"0000" & reg_coeff_scale;
            when others =>
                if (idx >= IDX_COEFF0) and (idx <= IDX_COEFF80) then
                    rdata_i <= x"0000" & coeff_regs(idx - IDX_COEFF0);
                end if;
        end case;
    end process;

    s_axi_rdata <= rdata_i;
    s_axi_bresp <= "00";
    s_axi_rresp <= "00";

    -- READ state masina
    read_fsm : process (s_axi_aclk) is
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_arready <= '0';
                axi_rvalid  <= '0';
                fsm_axi_read_state <= ReadAddress;
            else
                case fsm_axi_read_state is
                    when ReadAddress =>
                        axi_arready <= '1';
                        if (axi_arready = '1' and s_axi_arvalid = '1') then
                            axi_araddr  <= s_axi_araddr;
                            axi_arready <= '0';
                            axi_rvalid  <= '1';
                            fsm_axi_read_state <= ReadData;
                        end if;
                    when ReadData =>
                        if (s_axi_rready = '1' and axi_rvalid = '1') then
                            axi_rvalid  <= '0';
                            axi_arready <= '1';
                            fsm_axi_read_state <= ReadAddress;
                        end if;
                end case;
            end if;
        end if;
    end process;

    s_axi_arready <= axi_arready;
    s_axi_rvalid  <= axi_rvalid;

    -- WRITE state masina
    write_fsm : process (s_axi_aclk) is
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_awready <= '0';
                axi_wready  <= '0';
                axi_bvalid  <= '0';
                fsm_axi_write_state <= WriteAddress;
            else
                case fsm_axi_write_state is
                    when WriteAddress =>
                        axi_awready <= '1';
                        axi_wready  <= '1';
                        if (axi_awready = '1' and s_axi_awvalid = '1') then
                            axi_awaddr <= s_axi_awaddr;
                            if (axi_wready = '1' and s_axi_wvalid = '1') then
                                axi_bvalid <= '1';
                                if (s_axi_bready = '0') then
                                    axi_awready <= '0';
                                    axi_wready  <= '0';
                                    fsm_axi_write_state <= WriteStalled;
                                end if;
                            else
                                axi_awready <= '0';
                                fsm_axi_write_state <= WriteData;
                                if (s_axi_bready = '1' and axi_bvalid = '1') then
                                    axi_bvalid <= '0';
                                end if;
                            end if;
                        else
                            if (s_axi_bready = '1' and axi_bvalid = '1') then
                                axi_bvalid <= '0';
                            end if;
                        end if;

                    when WriteData =>
                        if (axi_wready = '1' and s_axi_wvalid = '1') then
                            axi_bvalid <= '1';
                            if (s_axi_bready = '0') then
                                axi_awready <= '0';
                                axi_wready  <= '0';
                                fsm_axi_write_state <= WriteStalled;
                            else
                                axi_awready <= '1';
                                axi_wready  <= '1';
                                fsm_axi_write_state <= WriteAddress;
                            end if;
                        else
                            if (s_axi_bready = '1' and axi_bvalid = '1') then
                                axi_bvalid <= '0';
                            end if;
                        end if;

                    when WriteStalled =>
                        if (s_axi_bready = '1' and axi_bvalid = '1') then
                            axi_bvalid  <= '0';
                            axi_awready <= '1';
                            axi_wready  <= '1';
                            fsm_axi_write_state <= WriteAddress;
                        end if;

                    when others =>
                        axi_awready <= '0';
                        axi_wready  <= '0';
                        axi_bvalid  <= '0';
                        fsm_axi_write_state <= WriteAddress;
                end case;
            end if;
        end if;
    end process;

    s_axi_awready <= axi_awready;
    s_axi_wready  <= axi_wready;
    s_axi_bvalid  <= axi_bvalid;

    axi_write_ready <= '1' when ((fsm_axi_write_state = WriteAddress and s_axi_awvalid = '1' and s_axi_wvalid = '1') or
                                 (fsm_axi_write_state = WriteData and s_axi_wvalid = '1')) else '0';

    -- Izlazi registara
    reg_ctrl_out        <= reg_ctrl;
    reg_radius_out      <= reg_radius;
    reg_img_w_out       <= reg_img_w;
    reg_img_h_out       <= reg_img_h;
    reg_coeff_scale_out <= reg_coeff_scale;

    gen_coeff : for i in 0 to 80 generate
        coeff_w_out((i+1)*16-1 downto i*16) <= coeff_regs(i);
    end generate;

end Behavioral;