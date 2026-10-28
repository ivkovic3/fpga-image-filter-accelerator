library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity line_buffer is
    generic (C_MAX_IMG_WIDTH : integer := 512);
    port(
        aclk         : in  std_logic;
        aresetn      : in  std_logic;

        pixel_in     : in  std_logic_vector(7 downto 0);   -- od handlera
        pixel_valid  : in  std_logic;                      -- od handlera
        reg_radius   : in  std_logic_vector(15 downto 0);
        reg_img_w    : in  std_logic_vector(15 downto 0);
        reg_img_h    : in  std_logic_vector(15 downto 0);
        next_ready   : out std_logic;                      -- nazad ka handleru

        column_out   : out std_logic_vector(71 downto 0);  -- ka ALU (9 bajtova)
        column_valid : out std_logic;
        column_en    : out std_logic;
        row_start    : out std_logic;

        alu_ready    : in  std_logic                       -- od ALU
    );
end line_buffer;

architecture Behavioral of line_buffer is

    -- Jedna 2D memorija: C_MAX_IMG_WIDTH lokacija x 64 bita
    -- Rec drzi celu kolonu susedstva (8 redova, po 1 bajt)
    -- Najstariji red je u gornjem bajtu [63:56], najnoviji u [7:0]
    type ram_type is array (0 to C_MAX_IMG_WIDTH - 1) of std_logic_vector(63 downto 0);
    signal line_ram : ram_type;

    signal img_w_int    : integer range 0 to C_MAX_IMG_WIDTH;
    signal img_h_int    : integer range 0 to 65535;
    signal radius_int   : integer range 0 to 4;

    -- Adresa/broj kolone koju TRENUTNO citamo
    signal column_count : integer range 0 to C_MAX_IMG_WIDTH - 1 := 0;
    signal row_count    : integer range 0 to 65535 := 0;

    -- Registrovano citanje iz BRAM-a (stigne jedan takt kasnije)
    signal rd_word      : std_logic_vector(63 downto 0);

  
    -- Pipeline za upis (kasni 1 takt za citanjem) 
   
    signal waddr        : integer range 0 to C_MAX_IMG_WIDTH - 1 := 0;  -- adresa upisa
    signal wr_en_d      : std_logic := '0';                              -- da li ima upisa
    signal pixel_in_d   : std_logic_vector(7 downto 0) := (others => '0');
    signal first_row_d  : std_logic := '0';   -- da li se upisuje PRVI red slike

    -- Pipeline za column_out/valid (poravnato sa rd_word u taktu N+1)
    signal col_en_d     : std_logic := '0';
    signal row_start_d  : std_logic := '0';
    signal row_cnt_d    : integer range 0 to 65535 := 0;

begin

    img_w_int  <= to_integer(unsigned(reg_img_w));
    img_h_int  <= to_integer(unsigned(reg_img_h));
    radius_int <= to_integer(unsigned(reg_radius));

    next_ready <= alu_ready;

    
  
    --    Citanje  - na adresu column_count (tekuca kolona)
    --    Upis     - na adresu waddr (kolona od PROSLOG takta)
  
    mem_proc : process (aclk)
        variable new_word : std_logic_vector(63 downto 0);
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                column_count <= 0;
                row_count    <= 0;
                waddr        <= 0;
                wr_en_d      <= '0';
                pixel_in_d   <= (others => '0');
                first_row_d  <= '0';
                col_en_d     <= '0';
                row_start_d  <= '0';
                row_cnt_d    <= 0;
                rd_word      <= (others => '0');
            else
                
                -- UPIS (izvrsava se za podatke pripremljene PROSLOG takta)
                -- Upisuje se na waddr, koji je "prethodni" column_count
                
                if wr_en_d = '1' then
                    if first_row_d = '1' then
                        -- Prvi red slike: nema istorije, sve bajtove popuni tekucim pikselom 
                        new_word := pixel_in_d & pixel_in_d & pixel_in_d & pixel_in_d &
                                    pixel_in_d & pixel_in_d & pixel_in_d & pixel_in_d;
                    else
                        -- Sift za 8 ulevo: najstariji bajt [63:56] ispada,
                        -- novi piksel ulazi u [7:0] rd_word je STARA rec te kolone
                        new_word := rd_word(55 downto 0) & pixel_in_d;
                    end if;
                    line_ram(waddr) <= new_word;
                end if;

                
                -- Citanje tekuce kolone (registrovan izlaz -> rd_word)
                --    Uvek kad stize validan piksel citamo kolonu koju cemo
                --    poslati ALU-u i koju cemo (siftovanu) upisati sledeci takt
              
                if pixel_valid = '1' then
                    rd_word <= line_ram(column_count);

                    -- pripremi UPIS za sledeci takt (na tekucu adresu/piksel)
                    waddr       <= column_count;
                    pixel_in_d  <= pixel_in;
                    wr_en_d     <= '1';
                    if row_count = 0 then
                        first_row_d <= '1';
                    else
                        first_row_d <= '0';
                    end if;

                    -- pipeline za column_out/valid (poravnato sa rd_word)
                    row_cnt_d <= row_count;
                    col_en_d  <= '1';
                    if column_count = 0 then
                        row_start_d <= '1';
                    else
                        row_start_d <= '0';
                    end if;

                    --  kraj reda?
                    if column_count = img_w_int - 1 then
                        column_count <= 0;
                        row_count    <= row_count + 1;
                    else
                        column_count <= column_count + 1;
                    end if;
                else
                    wr_en_d  <= '0';
                    col_en_d <= '0';
                end if;
            end if;
        end if;
    end process;

    
    -- Formiranje kolone za ALU (takt N+1: rd_word je sada validan)
   
    
    out_proc : process (aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                column_out   <= (others => '0');
                column_valid <= '0';
                column_en    <= '0';
                row_start    <= '0';
            else
                if col_en_d = '1' then
                    column_out <= rd_word & pixel_in_d;
                    column_en  <= '1';
                    row_start  <= row_start_d;

                    -- Validan izlaz tek kad je vertikalni susedstvo puno
                    if row_cnt_d >= 2 * radius_int and row_cnt_d < img_h_int then
                        column_valid <= '1';
                    else
                        column_valid <= '0';
                    end if;
                else
                    column_en    <= '0';
                    column_valid <= '0';
                    row_start    <= '0';
                end if;
            end if;
        end if;
    end process;

end Behavioral;