library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity acc_image_filter is
    port(
        s_axi_aclk    : in STD_LOGIC;
        s_axi_aresetn : in STD_LOGIC;

        s_axi_awaddr  : in STD_LOGIC_VECTOR (15 downto 0);
        s_axi_awvalid : in STD_LOGIC;
        s_axi_awready : out STD_LOGIC;
        s_axi_wdata   : in STD_LOGIC_VECTOR (31 downto 0);
        s_axi_wvalid  : in STD_LOGIC;
        s_axi_wready  : out STD_LOGIC;
        s_axi_bresp   : out STD_LOGIC_VECTOR (1 downto 0);
        s_axi_bvalid  : out STD_LOGIC;
        s_axi_bready  : in STD_LOGIC;
        s_axi_araddr  : in STD_LOGIC_VECTOR (15 downto 0);
        s_axi_arvalid : in STD_LOGIC;
        s_axi_arready : out STD_LOGIC;
        s_axi_rdata   : out STD_LOGIC_VECTOR (31 downto 0);
        s_axi_rvalid  : out STD_LOGIC;
        s_axi_rresp   : out STD_LOGIC_VECTOR (1 downto 0);
        s_axi_rready  : in STD_LOGIC;

        -- AXI-Stream ulaz (8 bita)
        s_axis_tvalid : in std_logic;
        s_axis_tready : out std_logic;
        s_axis_tdata  : in std_logic_vector(7 downto 0);

        -- AXI-Stream izlaz (16 bita)
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tdata  : out std_logic_vector(15 downto 0);
        m_axis_tlast  : out std_logic                    -- NOVO
    );
end acc_image_filter;

architecture Behavioral of acc_image_filter is
    -- handler - line_buffer
    signal pixel_data   : std_logic_vector(7 downto 0);
    signal pixel_valid  : std_logic;
    signal next_ready   : std_logic;
    -- line_buffer - alu
    signal column_data  : std_logic_vector(71 downto 0);
    signal column_valid : std_logic;
    signal column_en    : std_logic;
    signal row_start    : std_logic;
    signal alu_ready    : std_logic;
    -- alu - output
    signal result_data  : std_logic_vector(15 downto 0);
    signal result_valid : std_logic;
    signal result_last  : std_logic;                     -- NOVO
    -- registri
    signal reg_ctrl        : std_logic_vector(15 downto 0);
    signal reg_radius      : std_logic_vector(15 downto 0);
    signal reg_img_w       : std_logic_vector(15 downto 0);
    signal reg_img_h       : std_logic_vector(15 downto 0);
    signal reg_coeff_scale : std_logic_vector(15 downto 0);
    signal coeff_w         : std_logic_vector(1295 downto 0);
    
    
begin

    axi_lite_inst : entity work.pokusaj
    port map (
        s_axi_aclk => s_axi_aclk, s_axi_aresetn => s_axi_aresetn,
        s_axi_awaddr => s_axi_awaddr, s_axi_awvalid => s_axi_awvalid, s_axi_awready => s_axi_awready,
        s_axi_wdata => s_axi_wdata, s_axi_wvalid => s_axi_wvalid, s_axi_wready => s_axi_wready,
        s_axi_bresp => s_axi_bresp, s_axi_bvalid => s_axi_bvalid, s_axi_bready => s_axi_bready,
        s_axi_araddr => s_axi_araddr, s_axi_arvalid => s_axi_arvalid, s_axi_arready => s_axi_arready,
        s_axi_rdata => s_axi_rdata, s_axi_rvalid => s_axi_rvalid, s_axi_rresp => s_axi_rresp, s_axi_rready => s_axi_rready,
        reg_ctrl_out => reg_ctrl, reg_radius_out => reg_radius,
        reg_img_w_out => reg_img_w, reg_img_h_out => reg_img_h,
        reg_coeff_scale_out => reg_coeff_scale, coeff_w_out => coeff_w
    );

    input_inst : entity work.axis_input_handler
    port map (
        aclk => s_axi_aclk, aresetn => s_axi_aresetn,
        s_axis_tvalid => s_axis_tvalid, s_axis_tready => s_axis_tready, s_axis_tdata => s_axis_tdata,
        next_ready => next_ready, pixel_out => pixel_data, pixel_valid => pixel_valid
    );

    line_buffer_inst : entity work.line_buffer
    port map (
        aclk => s_axi_aclk, aresetn => s_axi_aresetn,
        pixel_in => pixel_data, pixel_valid => pixel_valid,
        reg_radius => reg_radius, reg_img_w => reg_img_w, reg_img_h => reg_img_h,
        next_ready => next_ready,
        column_out => column_data, column_valid => column_valid,
        column_en => column_en, row_start => row_start,
        alu_ready => alu_ready
    );

    alu_inst : entity work.alu_unit
    port map (
        aclk => s_axi_aclk, aresetn => s_axi_aresetn,
        column_in => column_data, column_valid => column_valid,
        row_start => row_start, column_en => column_en,
        reg_radius => reg_radius, reg_coeff_scale => reg_coeff_scale, reg_ctrl => reg_ctrl,
        reg_img_w => reg_img_w, reg_img_h => reg_img_h,          
        coeffs_w => coeff_w, result_ready => '1',
        alu_ready => alu_ready,
        result_out => result_data, result_valid => result_valid,
        result_last => result_last                               
    );

    output_inst : entity work.axis_output_handler
    port map (
        aclk => s_axi_aclk, aresetn => s_axi_aresetn,
        mode => reg_ctrl(0),
        result_in => result_data, result_valid_in => result_valid,
        result_last_in => result_last,                           
        m_axis_tvalid => m_axis_tvalid, m_axis_tready => m_axis_tready,
        m_axis_tdata => m_axis_tdata,
        m_axis_tlast => m_axis_tlast                             
    );

end Behavioral;