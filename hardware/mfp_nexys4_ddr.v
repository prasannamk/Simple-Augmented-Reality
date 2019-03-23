// mfp_nexys4_ddr.v
// February 22, 2019
//
// Instantiate the mipsfpga system and rename signals to
// match the GPIO, LEDs and switches on Digilent's (Xilinx)
// Nexys4 DDR board

// Outputs:
// 16 LEDs (IO_LED) 
// Seven segment signals
// VGA signals
// Camera clock and SCL SDA
// Inputs:
// 16 Slide switches (IO_Switch),
// 5 Pushbuttons (IO_PB): {BTNU, BTND, BTNL, BTNC, BTNR}
// Camera Data and timing signals

`include "mfp_ahb_const.vh"

module mfp_nexys4_ddr( 
                        input                   		CLK100MHZ,
                        input                   		CPU_RESETN,
                        input                   		BTNU, BTND, BTNL, BTNC, BTNR, 
                        input  	   [`MFP_N_SW-1 :0] 	SW,
                        output 	   [`MFP_N_LED-1:0] LED,
						output 						CA, CB, CC, CD, CE, CF, CG,
						output 						DP,
						output     [`MFP_N_SEG-1:0]	AN,
						
						//Signals for VGA
						output     [3			:0]	VGA_R,
						output     [3			:0]	VGA_G,
						output     [3			:0]	VGA_B,
						output     					VGA_HS,
						output     					VGA_VS,
						
						//camera module
						output 						cam_xck,
						output 						cam_scl,
						inout 						cam_sda,
						input 		[7:0] 			cam_data,
						input 						cam_vs,
						input 						cam_hs,
						input 						cam_pck,
						
                        inout  	   [ 8          :1] JB,
                        input                   	UART_TXD_IN);

		
	//Press btnCpuReset to reset the processor. 
	//signals use for debouncing module
	wire CPU_RESETN_DB;
	wire BTNU_DB;
	wire BTND_DB;
	wire BTNL_DB;
	wire BTNC_DB;
	wire BTNR_DB;
	wire [`MFP_N_SW-1 :0] SW_DB;	
		
		
	//clock for MIPS
	wire clk_out; 
	//clock for faster modules
	wire clk_out_75MHZ;
	//clock for camera module, DTG
	wire clk_out_25MHZ;
	
	wire tck_in, tck;
	
	//camera related signals
	//Indicator of configuration status
	wire done_config; 
	
	//signals for image display
	//generated by dtg and scale_image, consumed by block memory 
    wire [16:0] frame_addr;
	//generated by block memory, consumed by coloriser 
    wire [11:0] frame_pixel;
	//signals for camera 
	//generated by capture 
    wire [16:0] capture_addr;
    wire [11:0] capture_data;
    reg capture_we;


	//filter related signals	
	wire [16:0] filter_read_addr;
	//filter data is used by filter block
	wire [11:0] filter_read_data;
	

	//signals for main state machine
	//state variables
	reg [3:0] curr_state;
	reg [3:0] next_state;
	
	//start capture
	reg photo_start;
	//wait till its started, comes from photo_sm
	wire photo_started;
	//wait till its done, comes from photo_sm
	wire photo_done;
	//acknowledge it
	reg photo_ack;
	wire photo_error;
	
	//hand shaking signals for min and max
	reg min_max_start;
	wire min_max_started;
	wire min_max_done;
	wire min_max_error;
	reg min_max_ack;
	
	//outputs of min and max module
	//used by overlapping module
	wire [8:0] x_min;
	wire [8:0] x_max;
	
	wire [8:0] y_min;
	wire [8:0] y_max;
	
	wire [8:0] x_cen;
	wire [8:0] y_cen;
	
	wire [9:0] x_min_max_sum;
	wire [9:0] y_min_max_sum;
	
	//used to compute ceneter coordinate
	assign x_min_max_sum = x_min + x_max;
	assign y_min_max_sum = y_min + y_max;
	
	IBUF IBUF1(.O(tck_in),.I(JB[4]));
	BUFG BUFG1(.O(tck), .I(tck_in));
	
	//instance of debounce
	debounce debounce(
		.clk(clk_out),
		.pbtn_in({CPU_RESETN,BTNU,BTND,BTNL,BTNC,BTNR}),
		.switch_in(SW),
		.pbtn_db({CPU_RESETN_DB,BTNU_DB,BTND_DB,BTNL_DB,BTNC_DB,BTNR_DB}),
		.swtch_db(SW_DB)
	);
	
	//changes in clock wizard to add clock out of 75MHz
	clk_wiz_0 clk_wiz_0(.clk_in1(CLK100MHZ), .clk_out1(clk_out), .clk_out2(clk_out_75MHZ)
										   , .clk_out3(clk_out_25MHZ));
										   
	
	//video_on signal tells us what to do at blanking time
	wire video_on;
	//genetrated from DTG, consumed by image_scale block
	wire [11:0] pixel_row;
	wire [11:0] pixel_column;
	
	//instance of dtg
	//used for VGA and block memory
	dtg dtg(
		.clock(clk_out_25MHZ),
		.rst(~CPU_RESETN_DB),
		.horiz_sync(VGA_HS),
		.vert_sync(VGA_VS),
		.video_on(video_on),
		.pixel_row(pixel_row),
		.pixel_column(pixel_column)
	);
	
	//blank disp comes from scalar block only
	//to disable the display for desired location
	wire blank_disp;
	
	//instance of scale_image
	//maps 640*480 to 320*240
	//and gets the cooresponding address for the pixel
	//this is used to display background
	scale_image scale_image(
		.video_on(video_on),
		.pixel_row(pixel_row),
		.pixel_column(pixel_column),
		.image_addr(frame_addr),
		.blank_disp(blank_disp)
	);
	
	//based on this 
	wire [2:0] superimpose_pixel;
	
	//For different image selection
	//we have four different inages for the demo
	wire [11:0] top_left_1;
	wire [11:0] top_right_1;
	wire [11:0] bottom_left_1;
	wire [11:0] bottom_right_1;
	
	wire [11:0] top_left_2;
	wire [11:0] top_right_2;
	wire [11:0] bottom_left_2;
	wire [11:0] bottom_right_2;
	
	wire [11:0] top_left_3;
	wire [11:0] top_right_3;
	wire [11:0] bottom_left_3;
	wire [11:0] bottom_right_3;
	
	wire [11:0] top_left_4;
	wire [11:0] top_right_4;
	wire [11:0] bottom_left_4;
	wire [11:0] bottom_right_4;

	//generated by capture 
	//used for storing feed into block mem or not
	wire capture_we_inter;

	//used to control features for application
	//comes from MIPS fpga system
	wire [7:0] PORT_IP_CTRL;
	
	//using these values small image will be mapped on screen
	//these values can come from a block memory
	assign top_left_1 = 12'hF00;
	assign top_right_1 = 12'hFF0;
	assign bottom_left_1 = 12'hF0F;
	assign bottom_right_1 = 12'h0FF;
	
	assign top_left_2 = 12'hF0F;
	assign top_right_2 = 12'h0FF;
	assign bottom_left_2 = 12'hF00;
	assign bottom_right_2 = 12'hFF0;
	
	assign top_left_3 = 12'hF80;
	assign top_right_3 = 12'h08F;
	assign bottom_left_3 = 12'h00F;
	assign bottom_right_3 = 12'hFF0;
	
	assign top_left_4 = 12'hFF0;
	assign top_right_4 = 12'hF80;
	assign bottom_left_4 = 12'h08F;
	assign bottom_right_4 = 12'h00F;
	
	//select with which image box should be replaced  
	wire [1:0] superimpose_sel;
	
	reg [11:0] top_left;
	reg [11:0] top_right;
	reg [11:0] bottom_left;
	reg [11:0] bottom_right;
	
	//comes from AHB lite or HW switches direcytly
	// assign superimpose_sel = {SW_DB[2],SW_DB[1]};
	assign superimpose_sel = {PORT_IP_CTRL[2],PORT_IP_CTRL[1]};
	
	//Mux design for image selection
	always@(*)
	begin
		case(superimpose_sel)
			2'b00:
			begin
				top_left = top_left_1;
				top_right = top_right_1;
				bottom_left = bottom_left_1;
				bottom_right = bottom_right_1;
			end
			
			2'b01:
			begin
				top_left = top_left_2;
				top_right = top_right_2;
				bottom_left = bottom_left_2;
				bottom_right = bottom_right_2;
			end
			
			2'b10:
			begin
				top_left = top_left_3;
				top_right = top_right_3;
				bottom_left = bottom_left_3;
				bottom_right = bottom_right_3;
			end
			
			2'b11:
			begin
				top_left = top_left_4;
				top_right = top_right_4;
				bottom_left = bottom_left_4;
				bottom_right = bottom_right_4;
			end
		endcase
	end
	
	
	//instance of colorizer
	//which actually takes care of coloring
	//actually prints value on VGA screen based on background and superimposition
	colorizer colorizer(
		.video_on(video_on),
		.blank_disp(blank_disp),
		.op_pixel(frame_pixel),
		.superimpose_pixel(superimpose_pixel),
		
		.top_left_r(top_left[11:8]),
		.top_left_g(top_left[7:4]),
		.top_left_b(top_left[3:0]),
		
		.top_right_r(top_right[11:8]),
		.top_right_g(top_right[7:4]),
		.top_right_b(top_right[3:0]),
		
		.bottom_left_r(bottom_left[11:8]),
		.bottom_left_g(bottom_left[7:4]),
		.bottom_left_b(bottom_left[3:0]),
		
		.bottom_right_r(bottom_right[11:8]),
		.bottom_right_g(bottom_right[7:4]),
		.bottom_right_b(bottom_right[3:0]),
		
		.red(VGA_R),
		.green(VGA_G),
		.blue(VGA_B)
	);
	
	//select whether blue color or green color filter
	wire filter_sel;
	//from AHB
	// assign filter_sel = SW_DB[3];
	assign filter_sel = PORT_IP_CTRL[3];
	
	//filter block
	//generates address
	//reads pixel by pixel
	//computes min max boundarie for box of specific color
	filter filter(
		.clk(clk_out_25MHZ),	
		.reset(~CPU_RESETN_DB),	
		.ack_flag(min_max_ack),
		.start_flag(min_max_start),
		.color_sel(filter_sel),
		.data_pixel(filter_read_data),
		.address_to_read(filter_read_addr),
		.x_min(x_min),
		.x_max(x_max),
		.y_min(y_min),
		.y_max(y_max),
		.done_flag(min_max_done),
		.error_flag(min_max_error)
	);
	
	//signal to enable or disbale overlap
	wire disable_overlap;
	
	// assign disable_overlap = SW_DB[0];
	assign disable_overlap = PORT_IP_CTRL[0];
	
	//instance of overlap_image
	//helps coloriser to make decision between patch and background 
	overlap_image overlap_image(
		.x_min(x_min)
		,.x_max(x_max)
		,.y_min(y_min)
		,.y_max(y_max)
		,.x_cen(x_min_max_sum[9:1])
		,.y_cen(y_min_max_sum[9:1])
		,.pixel_row(pixel_row)
		,.pixel_column(pixel_column)
		,.disable_overlap(disable_overlap)
		,.swap_pixel(superimpose_pixel)
	);
	
	//clock signal for camera
	assign cam_xck = clk_out_25MHZ;
	
	//camera config module
	//configures the camera on switch
	//initally camera data is in YCrBr formate
	//we configure it to RGB format
	camera_configure CCONF(
        .clk(clk_out_25MHZ),
        .start(SW_DB[15]),
        .sioc(cam_scl),
        .siod(cam_sda),
        .done(done_config)
        );
		
	//block memory instance for 320*240 image
	//used for display purpose
	blk_mem_gen_0 fb1(
			.clka(cam_pck),
			.wea(capture_we),
			.addra(capture_addr),
			.dina(capture_data),
			.clkb(clk_out_25MHZ),
			.addrb(frame_addr),
			.doutb(frame_pixel)
        );
		
	//block memory for 320*240 image
	//used for image processing block
	blk_mem_gen_1 fb2(
			.clka(cam_pck),
			.wea(capture_we),
			.addra(capture_addr),
			.dina(capture_data),
			.clkb(clk_out_25MHZ),
			.addrb(filter_read_addr),
			.doutb(filter_read_data)
        );
		
	
	
	//main stated machine
	//captures the data 
	//writes into both memory
	//one memory is used for displaying
	//one memory is used for processing
	//hand shaking signals are generated from this state machine
	//states of main state machine
	localparam SM_RESET = 0;		
    localparam SM_TAKE_PHOTO_START = 1;
    localparam SM_TAKE_PHOTO_STARTED = 2;
    localparam SM_TAKE_PHOTO_EXEC = 3;
    localparam SM_TAKE_PHOTO_DONE = 4;
    localparam SM_TAKE_PHOTO_ACK = 5;
    localparam SM_MIN_MAX_START = 6;
    localparam SM_MIN_MAX_EXEC = 7;
    localparam SM_MIN_MAX_DONE = 8;
    localparam SM_MIN_MAX_ACK = 9;
    localparam SM_MIN_MAX_ACK_WAIT = 10;
    localparam SM_ERROR = 11;
	
	//my fsm block
	//this block is the main executor
	//clock block of moore design
	always@(posedge clk_out_25MHZ)
	begin
		if(CPU_RESETN_DB == 1'b0)
			curr_state <= SM_RESET;
		else
			curr_state <= next_state;
	end
	
	//next state logic
	always@(curr_state,photo_started,photo_done,min_max_done)
	begin
		case(curr_state)
			SM_RESET:
			begin
				next_state = SM_TAKE_PHOTO_START;
				// next_state = SM_MIN_MAX_START;
			end
			
			//start capture of photo
			SM_TAKE_PHOTO_START:
			begin
				next_state = SM_TAKE_PHOTO_STARTED;
			end
			
			//wait for started signal
			SM_TAKE_PHOTO_STARTED:
			begin
				if(photo_started == 1'b1)
					next_state = SM_TAKE_PHOTO_EXEC;
			end
			
			//wait till done
			SM_TAKE_PHOTO_EXEC:
			begin
				if(photo_done == 1'b1)
					next_state = SM_TAKE_PHOTO_DONE;
			end
			
			SM_TAKE_PHOTO_DONE:
			begin
				next_state = SM_TAKE_PHOTO_ACK;
			end
			
			//acknowledge it
			SM_TAKE_PHOTO_ACK:
			begin
				next_state = SM_MIN_MAX_START;
			end	
			
			//start filtering and computatiuon of min and max
			SM_MIN_MAX_START:
			begin
				next_state = SM_MIN_MAX_EXEC;
			end	
			
			//wait for done
			SM_MIN_MAX_EXEC:
			begin
				if(min_max_done == 1'b1)
					next_state = SM_MIN_MAX_DONE;
			end	
			
			SM_MIN_MAX_DONE:
			begin
				next_state = SM_MIN_MAX_ACK;
			end
			
			//acknowledge it
			SM_MIN_MAX_ACK:
			begin
				next_state = SM_MIN_MAX_ACK_WAIT;
			end	
			
			SM_MIN_MAX_ACK_WAIT:
			begin
				// next_state = SM_TAKE_PHOTO_START;
				next_state = SM_MIN_MAX_START;
			end	
			
			SM_ERROR:
			begin
			end	
			
			default:
			begin
				next_state = SM_ERROR;
			end
		endcase
	end
	
	//Output function logic for the main state machine
	always@(curr_state)
	begin
		case(curr_state)
			SM_RESET:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b0;
				min_max_start = 1'b0;
				min_max_ack = 1'b0;
			end
			
			//generate start flags
			SM_TAKE_PHOTO_START:
			begin
				photo_start = 1'b1;
				photo_ack = 1'b0;
				min_max_start = 1'b0;
				min_max_ack = 1'b0;
			end
			
			//keep the start flag on 
			//helps to sunchronize case of different clock domains
			SM_TAKE_PHOTO_STARTED:
			begin
				photo_start = 1'b1;
				photo_ack = 1'b0;
				min_max_start = 1'b0;
				min_max_ack = 1'b0;
			end
			
			SM_TAKE_PHOTO_EXEC:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b0;
				min_max_start = 1'b0;
				min_max_ack = 1'b0;
			end
			
			SM_TAKE_PHOTO_DONE:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b1;
				min_max_start = 1'b0;
				min_max_ack = 1'b0;
			end
			
			//send ackonwledge for photo sm
			SM_TAKE_PHOTO_ACK:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b1;
				min_max_start = 1'b0;
				min_max_ack = 1'b0;
			end

			//start computation of min and max		
			SM_MIN_MAX_START:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b1;
				min_max_start = 1'b1;
				min_max_ack = 1'b0;
			end
			
			//wait for the execution
			SM_MIN_MAX_EXEC:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b1;
				min_max_start = 1'b1;
				min_max_ack = 1'b0;
			end
			
			//wait for the execution
			SM_MIN_MAX_DONE:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b1;
				min_max_start = 1'b0;
				min_max_ack = 1'b0;
			end
			
			//give acknowledge to filter module
			SM_MIN_MAX_ACK:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b0;
				min_max_start = 1'b0;
				min_max_ack = 1'b1;
			end
			
			//wait for 1 cycle for acknowledgment
			SM_MIN_MAX_ACK_WAIT:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b0;
				min_max_start = 1'b0;
				min_max_ack = 1'b1;
			end
			
			SM_ERROR:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b0;
				min_max_start = 1'b0;
				min_max_ack = 1'b0;
			end

			default:
			begin
				photo_start = 1'b0;
				photo_ack = 1'b0;
				min_max_start = 1'b0;
				min_max_ack = 1'b0;
			end
		endcase
	end

	//controls the write of block memories
	always@(*)
	begin
		//switch the commenting to switch between 
		//live and still image
		capture_we = capture_we_inter & photo_en;
		// capture_we = 1'b0;
	end
	
	//instance of photo_sm state machine
	//instance responsible for synchronous frame writing
	//works on the pixel clock
	//uses start flag as input to store the camera data
	//sends acknowledgment on completion
	photo_sm photo_sm(
		.clk(cam_pck),
		.reset(CPU_RESETN_DB),
		.start(photo_start),
		.ack(photo_ack),
		.vsync(cam_vs),
		.wen(photo_en),
		.started(photo_started),
		.done(photo_done),
		.error(photo_error)
	);
		
	//instance of camera capture
	//generates address for 320*240 image
	//also generates enable signal for block memory
	//main file which gets data from camera
	ov7670_capture_verilog ov7670_capture_verilog(
        .pclk(cam_pck),
        .vsync(cam_vs),
        .href(cam_hs),
        .d(cam_data),
        .addr(capture_addr),
        .dout(capture_data),
        .we(capture_we_inter));
	

	//MIPS FPGA system
	//responsible for configuration and GUI
	mfp_sys mfp_sys(
			        // .SI_Reset_N(CPU_RESETN),
			        .SI_Reset_N(CPU_RESETN_DB),
                    .SI_ClkIn(clk_out),
                    .HADDR(),
                    .HRDATA(),
                    .HWDATA(),
                    .HWRITE(),
					.HSIZE(),
                    .EJ_TRST_N_probe(JB[7]),
                    .EJ_TDI(JB[2]),
                    .EJ_TDO(JB[3]),
                    .EJ_TMS(JB[1]),
                    .EJ_TCK(tck),
                    .SI_ColdReset_N(JB[8]),
                    .EJ_DINT(1'b0),
                    // .IO_Switch(SW),
                    .IO_Switch(SW_DB),
                    // .IO_PB({BTNU, BTND, BTNL, BTNC, BTNR}),
					
                    .IO_PB({BTNU_DB, BTND_DB, BTNL_DB, BTNC_DB, BTNR_DB}),
                    .IO_LED(LED),
                    .IO_AN(AN),
                    .IO_CA(CA),
                    .IO_CB(CB),
                    .IO_CC(CC),
                    .IO_CD(CD),
                    .IO_CE(CE),
                    .IO_CF(CF),
                    .IO_CG(CG),
                    .IO_DP(DP),
					.PORT_IP_CTRL(PORT_IP_CTRL),
                    .UART_RX(UART_TXD_IN));
          
endmodule