library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;


-- alu_unit sa 4-stepenim pipeline-om:
--   STEPEN 1 : 81 mnozenja  pxs*coef            -> prodA_reg (81 proizvod)
--   STEPEN 2: sabiranje po grupama (9 grupa x 9)  -> partB1_reg (9 parc. suma)
--   STEPEN 3: sabiranje 9 parcijalnih suma        -> sumB_reg
--   STEPEN 4 : skaliranje + saturacija + izbor  -> result_out


entity alu_unit is
    port(
        aclk            : in std_logic;
        aresetn         : in std_logic;
        column_in       : in std_logic_vector(71 downto 0);
        column_valid    : in std_logic;
        row_start       : in std_logic;
        reg_radius      : in std_logic_vector(15 downto 0);
        reg_coeff_scale : in std_logic_vector(15 downto 0);
        reg_ctrl        : in std_logic_vector(15 downto 0);
        reg_img_w       : in std_logic_vector(15 downto 0);
        reg_img_h       : in std_logic_vector(15 downto 0);
        result_ready    : in std_logic;
        coeffs_w        : in std_logic_vector(1295 downto 0);
        column_en       : in std_logic;

        alu_ready       : out std_logic;
        result_out      : out std_logic_vector(15 downto 0);
        result_valid    : out std_logic;
        result_last     : out std_logic
    );
end alu_unit;

architecture Behavioral of alu_unit is

    type window_type is array (0 to 8) of std_logic_vector(71 downto 0);
    signal window       : window_type := (others => (others => '0'));

    signal col_in_row   : integer range 0 to 8 := 0;
    signal radius_int   : integer range 0 to 4;

    signal calc_en_d    : std_logic := '0';
    signal col_valid_d  : std_logic := '0';
    signal col_in_row_d : integer range 0 to 8 := 0;

    signal out_col      : integer range 0 to 65535 := 0;
    signal out_row      : integer range 0 to 65535 := 0;

    -- PIPELINE registri 
    type prod_array is array (0 to 80) of signed(31 downto 0);
    signal prodA_reg  : prod_array := (others => (others => '0'));   -- A -> B1

    type part_array is array (0 to 8) of signed(39 downto 0);
    signal partB1_reg : part_array := (others => (others => '0'));   -- B1 -> B2

    signal sumB_reg   : signed(39 downto 0) := (others => '0');      -- B2 -> C

    -- kontrolni flag-ovi kroz 4 stepena
    signal emitA, emitB1, emitB2 : std_logic := '0';
    signal lastA, lastB1, lastB2 : std_logic := '0';

begin

    radius_int <= to_integer(unsigned(reg_radius));
    alu_ready  <= '1';

    process (aclk, aresetn)
        variable px      : unsigned(7 downto 0);
        variable pxs     : signed(15 downto 0);
        variable coef    : signed(15 downto 0);
        variable p       : prod_array;
        variable ps      : signed(39 downto 0);
        variable sumv    : signed(39 downto 0);
        variable acc     : signed(39 downto 0);
        variable out_w   : integer range 0 to 65535;
        variable out_h   : integer range 0 to 65535;
        variable is_last : std_logic;
    begin
        if aresetn = '0' then
            -- reset samo kontrolnih signala 
            col_in_row   <= 0;
            calc_en_d    <= '0';
            col_valid_d  <= '0';
            col_in_row_d <= 0;
            out_col      <= 0;
            out_row      <= 0;
            emitA  <= '0'; 
            emitB1 <= '0'; 
            emitB2 <= '0';
            lastA  <= '0'; 
            lastB1 <= '0'; 
            lastB2 <= '0';
            result_valid <= '0';
            result_last  <= '0';
            result_out   <= (others => '0');

        elsif rising_edge(aclk) then

            out_w := to_integer(unsigned(reg_img_w)) - 2*radius_int;
            out_h := to_integer(unsigned(reg_img_h)) - 2*radius_int;

           
            -- ULAZNA FAZA: prijem kolone - azuriranje prozora
            
            if column_en = '1' then
                if row_start = '1' then
                    col_in_row <= 0;
                    window(8) <= column_in;
                    for i in 0 to 7 loop
                        window(i) <= (others => '0');
                    end loop;
                else
                    for i in 0 to 7 loop
                        window(i) <= window(i + 1);
                    end loop;
                    window(8) <= column_in;
                    if col_in_row < 2 * radius_int then
                        col_in_row <= col_in_row + 1;
                    end if;
                end if;

                calc_en_d   <= '1';
                col_valid_d <= column_valid;
                if row_start = '1' then
                    col_in_row_d <= 0;
                elsif col_in_row < 2 * radius_int then
                    col_in_row_d <= col_in_row + 1;
                else
                    col_in_row_d <= col_in_row;
                end if;
            else
                calc_en_d <= '0';
            end if;

            
            -- STEPEN 1: 81 mnozenja -> prodA_reg , odluka emit/last
            
            if calc_en_d = '1' then
                for i in 0 to 80 loop
                    p(i) := (others => '0');
                end loop;

                case radius_int is
                    when 1 =>
                        for r in 0 to 2 loop
                            for c in 0 to 2 loop
                                px   := unsigned(window(6+c)(((2-r)*8+7) downto ((2-r)*8)));
                                pxs  := resize(signed('0' & std_logic_vector(px)), 16);
                                coef := signed(coeffs_w((((r+3)*9+(c+3))*16+15) downto (((r+3)*9+(c+3))*16)));
                                p(r*3+c) := pxs * coef;
                            end loop;
                        end loop;
                    when 2 =>
                        for r in 0 to 4 loop
                            for c in 0 to 4 loop
                                px   := unsigned(window(4+c)(((4-r)*8+7) downto ((4-r)*8)));
                                pxs  := resize(signed('0' & std_logic_vector(px)), 16);
                                coef := signed(coeffs_w((((r+2)*9+(c+2))*16+15) downto (((r+2)*9+(c+2))*16)));
                                p(r*5+c) := pxs * coef;
                            end loop;
                        end loop;
                    when 3 =>
                        for r in 0 to 6 loop
                            for c in 0 to 6 loop
                                px   := unsigned(window(2+c)(((6-r)*8+7) downto ((6-r)*8)));
                                pxs  := resize(signed('0' & std_logic_vector(px)), 16);
                                coef := signed(coeffs_w((((r+1)*9+(c+1))*16+15) downto (((r+1)*9+(c+1))*16)));
                                p(r*7+c) := pxs * coef;
                            end loop;
                        end loop;
                    when 4 =>
                        for r in 0 to 8 loop
                            for c in 0 to 8 loop
                                px   := unsigned(window(0+c)(((8-r)*8+7) downto ((8-r)*8)));
                                pxs  := resize(signed('0' & std_logic_vector(px)), 16);
                                coef := signed(coeffs_w(((r*9+c)*16+15) downto ((r*9+c)*16)));
                                p(r*9+c) := pxs * coef;
                            end loop;
                        end loop;
                    when others =>
                        null;
                end case;

                for i in 0 to 80 loop
                    prodA_reg(i) <= p(i);
                end loop;

                if col_valid_d = '1' and col_in_row_d >= 2 * radius_int then
                    emitA <= '1';
                    is_last := '0';
                    if (out_col = out_w - 1) and (out_row = out_h - 1) then
                        is_last := '1';
                    end if;
                    lastA <= is_last;
                    if out_col = out_w - 1 then
                        out_col <= 0;
                        if out_row = out_h - 1 then
                            out_row <= 0;
                        else
                            out_row <= out_row + 1;
                        end if;
                    else
                        out_col <= out_col + 1;
                    end if;
                else
                    emitA <= '0';
                    lastA <= '0';
                end if;
            else
                emitA <= '0';
                lastA <= '0';
            end if;

           
            -- STEPEN 2: saberi po grupama (9 grupa po 9) -> partB1_reg
           
            for g in 0 to 8 loop
                ps := (others => '0');
                for k in 0 to 8 loop
                    ps := ps + resize(prodA_reg(g*9 + k), 40);
                end loop;
                partB1_reg(g) <= ps;
            end loop;
            emitB1 <= emitA;
            lastB1 <= lastA;

           
            -- STEPEN 3: saberi 9 parcijalnih suma -> sumB_reg
            
            sumv := (others => '0');
            for g in 0 to 8 loop
                sumv := sumv + partB1_reg(g);
            end loop;
            sumB_reg <= sumv;
            emitB2 <= emitB1;
            lastB2 <= lastB1;

            
            -- STEPEN 4: skaliranje + saturacija + izbor bita
            
            acc := resize(shift_right(sumB_reg * signed(reg_coeff_scale), 12), acc'length);

            if emitB2 = '1' then
                if reg_ctrl(0) = '0' then
                    if acc(39) = '1' then
                        result_out <= (others => '0');
                    elsif acc(38 downto 23) /= (38 downto 23 => '0') then
                        result_out <= x"00FF";
                    else
                        result_out <= x"00" & std_logic_vector(acc(22 downto 15));
                    end if;
                else
                    if (acc(39 downto 23) = (39 downto 23 => '0')) or
                       (acc(39 downto 23) = (39 downto 23 => '1')) then
                        result_out <= std_logic_vector(acc(23 downto 8));
                    elsif acc(39) = '0' then
                        result_out <= x"7FFF";
                    else
                        result_out <= x"8000";
                    end if;
                end if;
                result_valid <= '1';
                result_last  <= lastB2;
            else
                result_valid <= '0';
                result_last  <= '0';
            end if;

        end if;
    end process;

end Behavioral;