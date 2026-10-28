library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;


entity axis_output_handler is
    port(
        aclk            : in  std_logic;
        aresetn         : in  std_logic;
        mode            : in  std_logic;
        result_in       : in  std_logic_vector(15 downto 0);
        result_valid_in : in  std_logic;
        result_last_in  : in  std_logic;
        m_axis_tvalid   : out std_logic;
        m_axis_tready   : in  std_logic;
        m_axis_tdata    : out std_logic_vector(15 downto 0);
        m_axis_tlast    : out std_logic
    );
end axis_output_handler;

architecture Behavioral of axis_output_handler is

    -- Izlazni registri 
    signal tvalid_r : std_logic := '0';
    signal tdata_r  : std_logic_vector(15 downto 0) := (others => '0');
    signal tlast_r  : std_logic := '0';

    -- MODE 0 pakovanje
    signal have_first  : std_logic := '0';
    signal first_pixel : std_logic_vector(7 downto 0) := (others => '0');
    signal first_last  : std_logic := '0';

    -- Kad je izlaz zauzet a stigne nov piksel
    signal in_buf_valid : std_logic := '0';
    signal in_buf_data  : std_logic_vector(15 downto 0) := (others => '0');
    signal in_buf_last  : std_logic := '0';

    -- Da li izlaz moze da primi novu rec ovog takta
    signal out_free : std_logic;

begin

    -- Izlaz je slobodan ako nema validnog transfera ili je DMA upravo prihvatio
    out_free <= '1' when (tvalid_r = '0') or (tvalid_r = '1' and m_axis_tready = '1') else '0';

    process (aclk, aresetn)
        variable px_data : std_logic_vector(15 downto 0);
        variable px_last : std_logic;
        variable px_vld  : std_logic;
        variable produce : std_logic;                 -- da li ovog takta pravimo izlaznu rec
        variable out_data : std_logic_vector(15 downto 0);
        variable out_last : std_logic;
    begin
        if aresetn = '0' then
            tvalid_r     <= '0';
            tdata_r      <= (others => '0');
            tlast_r      <= '0';
            have_first   <= '0';
            first_pixel  <= (others => '0');
            first_last   <= '0';
            in_buf_valid <= '0';
            in_buf_data  <= (others => '0');
            in_buf_last  <= '0';

        elsif rising_edge(aclk) then

            -- Ako je DMA prihvatio tekuci transfer, oslobodi tvalid
            if tvalid_r = '1' and m_axis_tready = '1' then
                tvalid_r <= '0';
                tlast_r  <= '0';
            end if;

            -- Izaberi ulazni piksel
            if in_buf_valid = '1' then
                px_data := in_buf_data;
                px_last := in_buf_last;
                px_vld  := '1';
            elsif result_valid_in = '1' then
                px_data := result_in;
                px_last := result_last_in;
                px_vld  := '1';
            else
                px_data := (others => '0');
                px_last := '0';
                px_vld  := '0';
            end if;

            -- Obradi ulazni piksel samo ako izlaz moze da primi rec
            produce := '0';
            out_data := (others => '0');
            out_last := '0';

            if px_vld = '1' and out_free = '1' then
                if mode = '1' then
                    -- MODE 1: jedan 16-bit piksel po transferu
                    out_data := px_data;
                    out_last := px_last;
                    produce  := '1';
                else
                    -- MODE 0: pakujem 2 piksela
                    if have_first = '0' then
                        -- prvi piksel para
                        if px_last = '1' then
                            -- NEUPAREN poslednji: posalji ga sam, gornji bajt 0, TLAST
                            out_data := x"00" & px_data(7 downto 0);
                            out_last := '1';
                            produce  := '1';
                            have_first <= '0';
                        else
                            first_pixel <= px_data(7 downto 0);
                            first_last  <= px_last;
                            have_first  <= '1';
                            -- ne pravimo izlaznu rec jos
                        end if;
                    else
                        -- drugi piksel para -> slozi rec (drugi, prvi)
                        out_data := px_data(7 downto 0) & first_pixel;
                        out_last := px_last or first_last;
                        produce  := '1';
                        have_first <= '0';
                    end if;
                end if;

                -- Piksel je potrosen
                if in_buf_valid = '1' then
                    in_buf_valid <= '0';
                end if;

            elsif px_vld = '1' and out_free = '0' then
                -- Izlaz zauzet a stigao nov piksel sa ulaza 
                
                if in_buf_valid = '0' then
                    in_buf_data  <= px_data;
                    in_buf_last  <= px_last;
                    in_buf_valid <= '1';
                end if;
            end if;

            -- Ako smo napravili izlaznu rec, postavi je i drzi do handshake-a
            if produce = '1' then
                tdata_r  <= out_data;
                tlast_r  <= out_last;
                tvalid_r <= '1';
            end if;

        end if;
    end process;

    m_axis_tdata  <= tdata_r;
    m_axis_tvalid <= tvalid_r;
    m_axis_tlast  <= tlast_r;

end Behavioral;