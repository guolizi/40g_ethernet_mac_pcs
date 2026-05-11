module crc32 #(
    parameter CRC_INIT    = 32'hFFFFFFFF,
    parameter CRC_XOR_OUT = 32'hFFFFFFFF
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [127:0] data_in,
    input  wire [15:0]  byte_en,
    output wire [31:0]  crc_out,
    output wire         crc_valid
);

    reg [31:0] crc_reg;
    reg        valid_d1;
    reg        valid_d2;

    function [31:0] crc32_byte_reflected;
        input [31:0] crc;
        input [7:0]  byte_in;
        reg [31:0]   c;
        integer      i;
        begin
            c = crc;
            for (i = 0; i < 8; i = i + 1) begin
                if ((c[0] ^ byte_in[i]))
                    c = (c >> 1) ^ 32'hEDB88320;
                else
                    c = c >> 1;
            end
            crc32_byte_reflected = c;
        end
    endfunction

    function [31:0] crc32_128_with_en;
        input [31:0]  crc;
        input [127:0] data;
        input [15:0]  en;
        reg [31:0]    c;
        integer       i;
        begin
            c = crc;
            for (i = 0; i < 16; i = i + 1) begin
                if (en[i])
                    c = crc32_byte_reflected(c, data[i*8 +: 8]);
            end
            crc32_128_with_en = c;
        end
    endfunction

    wire [31:0] crc_base;
    wire [31:0] crc_next;

    assign crc_base = start ? CRC_INIT : crc_reg;
    assign crc_next = crc32_128_with_en(crc_base, data_in, byte_en);

    always @(posedge clk) begin
        if (!rst_n) begin
            crc_reg  <= 32'h0;
            valid_d1 <= 1'b0;
            valid_d2 <= 1'b0;
        end else begin
            if (start | (|byte_en)) begin
                crc_reg <= crc_next;
            end
            
            valid_d1 <= start;
            valid_d2 <= valid_d1;
        end
    end

    assign crc_out   = crc_reg ^ CRC_XOR_OUT;
    assign crc_valid = valid_d2;

endmodule
