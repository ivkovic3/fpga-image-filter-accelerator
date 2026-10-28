

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;



entity axis_input_handler is
    Port(
        aclk : in std_logic;
        aresetn : in std_logic;
        s_axis_tvalid : in std_logic;
        s_axis_tready : out std_logic;
        s_axis_tdata : in std_logic_vector(7 downto 0); --8-bitni piksel od DMA
        next_ready : in std_logic; --od line-buffer-a : mogu da primim 
        pixel_out : out std_logic_vector(7 downto 0); --ka line_buffer-u
        pixel_valid : out std_logic --ka line_buffer-u
         
    );
end axis_input_handler;

architecture Behavioral of axis_input_handler is

signal pixel_reg : std_logic_vector(7 downto 0) := (others => '0');
signal pixel_full : std_logic := '0'; 
signal tready_i : std_logic;  

begin
    process (aclk, aresetn)
    begin 
        if aresetn = '0' then
            
            pixel_valid <= '0';
            pixel_out <= (others =>'0');
            pixel_full <= '0';
                
        elsif rising_edge(aclk) then
            
            if pixel_full = '1' and next_ready = '1' then
                pixel_out <= pixel_reg;
                pixel_valid <= '1';
                pixel_full <= '0';
            else 
                pixel_valid <= '0';
                
            end if;    
            
            if s_axis_tvalid = '1' and tready_i = '1' then
                pixel_reg <= s_axis_tdata;
                pixel_full <= '1';
            end if;
            
        end if;
    
        
    
    end process;
    
    tready_i <= '1' when (pixel_full = '0' or (pixel_full = '1' and next_ready = '1'))
        else '0';
        
    s_axis_tready <= tready_i;


end Behavioral;
