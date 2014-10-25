;-----------------------------------------------------------------------------;
; PASVOL                                                                      ;
;                                                                             ;
; Small active TSR application to control the volume of PAS(16) cards via     ;
; Ctrl-Alt-PgUp and Ctrl-Alt-PgDn.                                            ;
;                                                                             ;
; Assemble with NASM.                                                         ;
;-----------------------------------------------------------------------------;
	org 0x100

section .text

start:
	jmp main

;-----------------------------------------------------------------------------;
; Resident Program Data                                                       ;
;-----------------------------------------------------------------------------;
; Activation flags
tsr_should_activate: db 0x00
tsr_is_active: db 0x00
pressed_key: db 0x00

; Original interrupt handler pointers
orig_int08: dd 0x00
orig_int09: dd 0x00
orig_int28: dd 0x00
orig_int2f: dd 0x00

; InDOS pointer
in_dos_ptr: dd 0x00

; PAS driver function pointers
pas_get_volume_ptr: dd 0x00
pas_set_volume_ptr: dd 0x00

;-----------------------------------------------------------------------------;
; Resident Code                                                               ;
;-----------------------------------------------------------------------------;
int_08:
	push ax                                 ; Save registers
	push bx
	push es

	cmp byte [cs:tsr_is_active], 0x00       ; Check if the TSR is already active
	jne int_08_end
	cmp byte [cs:tsr_should_activate], 0x00 ; Check to see if the TSR should be running
	je int_08_end
	 
	les bx, [cs:in_dos_ptr]
	mov al, byte [es:bx]                    ; Check InDOS
	or al, byte [es:bx-1]                   ; and CritErr flags
	cmp al, 0x00

	jne int_08_end

	call resident_main

int_08_end:
	pop es                                  ; Restore registers
	pop bx
	pop ax

	pushf
	call far [cs:orig_int08]
	iret

int_09:
	push ax                                 ; Save registers
	push es

	mov ax, 0x40
	mov es, ax

	mov al, byte [es:0x17]                  ; Check if Ctrl+Alt are pressed
	and al, 0b1100
	cmp al, 0b1100                          
	jne int_09_end

	in al, 0x60                             ; Read scancode
	cmp al, 0x49                            ; Check if PgUp is pressed
	je int_09_mark_activation
	cmp al, 0x51                            ; or PgDn
	je int_09_mark_activation

	jmp int_09_end

int_09_mark_activation:
	mov byte [cs:pressed_key], al           ; Save pressed key scancode
	mov byte [cs:tsr_should_activate], 0xff ; Mark to be activated

int_09_end:
	pop es                                  ; Restore registers
	pop ax

	pushf
	call far [cs:orig_int09]
	iret

int_28:
	cmp byte [cs:tsr_is_active], 0x00       ; Check if the TSR is already active
	jne int_28_end
	cmp byte [cs:tsr_should_activate], 0x00 ; Check to see if the TSR should be running
	je int_28_end

	call resident_main

int_28_end:
	pushf
	call far [cs:orig_int28]
	iret

int_2f:
	cmp ax, 0xfe00                          ; Check to see if the function call belongs to us.
	jne int_2f_end

	cmp bl, 0xa0                            ; In case another service provides function 0xfe, check if bl is equal to 0xa0
	jne int_2f_end
	xor bl, 0x51                            ; If it is, xor it with 0x51 to produce 0xf1. "Fe, fi (fo, fum)" (lame, right?)

int_2f_end:
	jmp far [cs:orig_int2f]

resident_main:
	mov byte [cs:tsr_is_active], 0xff       ; Mark as active
	mov byte [cs:tsr_should_activate], 0x00 

	push ax                                 ; Save registers
	push bx
	push cx

	cmp byte [cs:pressed_key], 0x49         ; PgUp key (increase volume)
	je pas_increase_volume
	cmp byte [cs:pressed_key], 0x51         ; PgDn key (decrease volume)
	jne resident_main_end

pas_decrease_volume:
	mov cx, 0x04                            ; Get current volume from left channel
	call far [cs:pas_get_volume_ptr]

	sub bx, 5                               ; Decrement volume by 5
	cmp bx, 0                               ; Check if target volume < 0
	jge pas_volume_set                      ; If not, set without modifications
	xor bx, bx                              ; If so, set volume to 0 
	jmp pas_volume_set

pas_increase_volume:
	mov cx, 0x04                            ; Get current volume from left channel
	call far [cs:pas_get_volume_ptr]

	add bx, 5                               ; Increment volume by 5
	cmp bx, 100                             ; Check if target volume > 1000
	jle pas_volume_set                      ; If not, set without modifications
	mov bx, 100                             ; If so, set volume to 100 (maximum)

pas_volume_set:
	call far [cs:pas_set_volume_ptr]        ; Set left channel
	mov cx, 0x05                            ; Set right channel
	call far [cs:pas_set_volume_ptr]
	
resident_main_end:
	pop cx                                  ; Restore registers
	pop bx
	pop ax
	mov byte [cs:tsr_is_active], 0x00       ; Mark as inactive

	ret

;-----------------------------------------------------------------------------;
; Transient Code                                                              ;
;-----------------------------------------------------------------------------;
main:
	mov bx, 0xa0                            ; Check if the TSR is already installed.
	mov ax, 0xfe00
	int 0x2f

	cmp bl, 0xf1
	jne pas_is_driver_loaded

already_installed:
	mov dx, word already_installed_msg      ; Print messenge indicating that the TSR is already installed.
	mov ah, 0x09
	int 0x21
	int 0x20

pas_is_driver_loaded:
	mov bx, 0x3f3f
	mov ax, 0xbc00                          ; Get identifier function
	int 0x2f                                ; Call function via interupt 2fh
	
	xor bx, cx                              ; Combine identifier parts into a single value
	xor bx, dx                              ; When XOR'd with 0x3f3f the id will equal 'MV'

	cmp bx, 0x4d56
	je pas_get_functions

pas_driver_not_installed:
	mov dx, word no_driver_msg              ; Print missing driver error
	mov ah, 0x09
	int 0x21

	mov ax, 0x4c01                          ; Terminate with return code 1
	int 0x21

pas_get_functions:
	mov ax, 0xbc03                          ; Get PAS driver's function table
	int 0x2f

	mov es, dx                              

	mov ax, [es:bx+4]
	mov word [cs:pas_set_volume_ptr+0], ax  ; Store pointer to "set volume" function
	mov word [cs:pas_set_volume_ptr+2], dx  ; Table segment is stored in dx

	mov ax, [es:bx+20]
	mov word [cs:pas_get_volume_ptr+0], ax  ; Store pointer to "get volume" function
	mov word [cs:pas_get_volume_ptr+2], dx

install:
	mov ah, 0x34
	int 0x21
	mov word [cs:in_dos_ptr+0], bx          ; Save InDOS offset
	mov word [cs:in_dos_ptr+2], es          ; and segment

	cli
	mov ah, 0x35                            ; Get interrupt handler

	mov al, 0x08
	int 0x21
	mov word [cs:orig_int08+0], bx          ; Save old interrupt 0x08 offset
	mov word [cs:orig_int08+2], es          ; and segment

	mov al, 0x09
	int 0x21
	mov word [cs:orig_int09+0], bx          ; Save old interrupt 0x09 offset
	mov word [cs:orig_int09+2], es          ; and segment

	mov al, 0x28
	int 0x21
	mov word [cs:orig_int28+0], bx          ; Save old interrupt 0x28 offset
	mov word [cs:orig_int28+2], es          ; and segment

	mov al, 0x2f
	int 0x21
	mov word [cs:orig_int2f+0], bx          ; Save old interrupt 0x2f offset
	mov word [cs:orig_int2f+2], es          ; and segment

	push ds
	push cs                                 ; cs = ds
	pop ds

	mov ah, 0x25                            ; Set interrupt handler
	
	mov dx, word int_08                     ; Install new interrupt 0x08 handler
	mov al, 0x08
	int 0x21

	mov dx, word int_09                     ; Install new interrupt 0x09 handler
	mov al, 0x09
	int 0x21

	mov dx, word int_28                     ; Install new interrupt 0x28 handler
	mov al, 0x28
	int 0x21

	mov dx, word int_2f                     ; Install new interrupt 0x2f handler
	mov al, 0x2f
	int 0x21

	pop ds
	sti

	mov dx, word installed_msg              ; Print "Installed" message
	mov ah, 0x09
	int 0x21

	mov dx, word 17 + ((main - start) / 16) ; Allocate 16 paragraphs for PSP + memory for the resident portion
	mov ax, 0x3100                          ; Terminate and stay resident
	int 0x21

;-----------------------------------------------------------------------------;
; Transient Program Data                                                      ;
;-----------------------------------------------------------------------------;
section .data

installed_msg: db "PASVOL installed.", 0x0d, 0x0a, 0x24
already_installed_msg: db "PASVOL is already installed.", 0x0d, 0x0a, 0x24
no_driver_msg: db "Error: PAS Driver not installed.", 0x0d, 0x0a, 0x24
