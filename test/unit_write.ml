
open OUnit
open Printf
module E = Extprot
open Test_types

let check_write ?msg expected f v () =
  let b = E.Msg_buffer.create () in
    f b v;
    assert_equal ?msg ~printer:(sprintf "%S") expected (E.Msg_buffer.contents b)

let bits n shift =
  Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical n shift) 0xFFL))

let check_bits64 check v n =
  check v
    (sprintf "\001\010\001\004%c%c%c%c%c%c%c%c"
       (bits n 0)  (bits n 8)  (bits n 16) (bits n 24)
       (bits n 32) (bits n 40) (bits n 48) (bits n 56))

let (@@) f x = f x

module Probabilistic =
struct
  open Rand_monad.Rand
  open Test_types.Complex_rtt
  module PP = E.Pretty_print

  let encode f v =
    let b = E.Msg_buffer.create () in
      f b v;
      E.Msg_buffer.contents b

  let decode f s = f @@ E.Codec.Reader.make s 0 (String.length s)

  let generate = run
  (* let rand_len = rand_integer 10 *)
  let rand_len = return 1

  let string_of_rtt =
    let pp_sum_type f1 f2 f3 pp = function
        Sum_type.A x -> PP.fprintf pp "A %a" f1 x
      | Sum_type.B x -> PP.fprintf pp "B %a" f2 x
      | Sum_type.C x -> PP.fprintf pp "C %a" f3 x in
    let print_rtta =
      PP.pp_struct
        [
          "Complex_rtt.a1",
          PP.pp_field (fun t -> t.a1)
            (PP.pp_list (PP.pp_tuple2 PP.pp_int (PP.pp_array PP.pp_bool)));

          "Complex_rtt.a2",
          PP.pp_field (fun t -> t.a2)
             (PP.pp_list (pp_sum_type PP.pp_int PP.pp_string PP.pp_int64));
        ] in
    let print_rttb pp t = PP.fprintf pp "{ ... }"
    in
      function
        A t -> PP.ppfmt "Complex_rtt.A %a" print_rtta t
      | B t -> PP.ppfmt "Complex_rtt.B %a" print_rttb t

  let rtt_a =
    let a1_elm =
      rand_int >>= fun n ->
      rand_array rand_len rand_bool >>= fun a ->
        return (n, a) in
    let a2_elm =
      rand_choice
        [
          (rand_int >>= fun n -> return (Sum_type.A n));
          (rand_string rand_len >>= fun s -> return (Sum_type.B s));
          (rand_int64 >>= fun n -> return (Sum_type.C n))
        ]
    in
      rand_list rand_len a1_elm >>= fun a1 ->
      rand_list rand_len a2_elm >>= fun a2 ->
      return (A { a1 = a1; a2 = a2 })

  let complex_rtt = rand_choice [ rtt_a ]

  let () = Register_test.register "RTT"
    [
      "complex" >:: begin fun () ->
        for i = 0 to 10 do
          let v = generate complex_rtt in
          let enc = encode write_complex_rtt v in
            try
              assert_equal ~printer:string_of_rtt v (decode read_complex_rtt enc)
            with E.Error.Extprot_error (err, msg) ->
              assert_failure @@
              sprintf "%s\nfor\n %s\nencoded as\n%s =\n%s"
                (PP.pp
                   (PP.pp_tuple2 ~constr:"Extprot_error"
                      E.Error.pp_extprot_error PP.pp_string)
                   (err, msg))
                (string_of_rtt v)
                (PP.pp PP.pp_dec_bytes enc)
                (PP.pp PP.pp_hex_bytes enc)
        done
      end;
    ]
end

let () =
  Register_test.register "write composed types"
    [
      "tuple" >::
        (*
         * 001        tuple, tag 0
         * NNN        len
         * 001        elements
         *  001        tuple, tag 0
         *  NNN        len
         *  002        elements
         *   000 010    vint(10)
         *   000 001    bool(true)
         * *)
        check_write "\001\008\001\001\005\002\000\010\000\001"
          ~msg:"{ Simple_tuple.v = (10, true) }"
          Simple_tuple.write_simple_tuple { Simple_tuple.v = (10, true) };

      "msg_sum" >:: begin fun () ->
        (*
         * 001      tuple, tag 0
         * 003      len
         * 001      nelms
         *  000 000  bool false
         * *)
        check_write "\001\003\001\000\000"
          ~msg:"(Msg_sum.A { Msg_sum.b = false })"
          Msg_sum.write_msg_sum (Msg_sum.A { Msg_sum.b = false }) ();
        (*
         * 017      tuple, tag 1
         * 003      len
         * 001      nelms
         *  000 000  bool false
         * *)
        check_write "\017\003\001\000\020"
          ~msg:"(Msg_sum.B { Msg_sum.i = 10 })"
          Msg_sum.write_msg_sum (Msg_sum.B { Msg_sum.i = 10 }) ()
      end;

      "simple_sum" >:: begin fun () ->
        (*
         * 001       tuple, tag 0
         * 006       len
         * 001       nelms
         *  001       tuple, tag 0
         *  003       len
         *  001       nelms
         *   000 001   bool true
         * *)
        check_write "\001\006\001\001\003\001\000\001"
          ~msg:"{ Simple_sum.v = Sum_type.A true }"
          Simple_sum.write_simple_sum { Simple_sum.v = Sum_type.A true } ();
        (*
         * 001       tuple, tag 0
         * 007       len
         * 001       nelms
         *  017       tuple, tag 1
         *  004       len
         *  001       nelms
         *   000 128 001  byte 128
         * *)
        check_write "\001\007\001\017\004\001\000\128\001"
          ~msg:"{ Simple_sum.v = Sum_type.B 128 }"
          Simple_sum.write_simple_sum { Simple_sum.v = Sum_type.B 128 } ();
        (*
         * 001       tuple, tag 0
         * 010       len
         * 001       nelms
         *  033       tuple, tag 2
         *  007       len
         *  001       nelms
         *   003 004 abcd  bytes "abcd"
         * *)
        check_write "\001\010\001\033\007\001\003\004abcd"
          ~msg:"{ Simple_sum.v = Sum_type.C \"abcd\" }"
          Simple_sum.write_simple_sum { Simple_sum.v = Sum_type.C "abcd" } ();
      end;

      "nested message" >:: begin fun () ->
        (* 001       tuple, tag 0
         * 015       len
         * 002       nelms
         *  001       tuple, tag 0
         *  010       len
         *  001       nelms
         *   033       tuple, tag 2
         *   007       len
         *   001       nelms
         *    003 004 abcd  bytes "abcd"
         *  000 020   int 10
         * *)
        check_write "\001\015\002\001\010\001\033\007\001\003\004abcd\000\020"
          Nested_message.write_nested_message
          ~msg:"{ Nested_message.v = { Simple_sum.v = Sum_type.C \"abcd\" }; b = 10 }"
          { Nested_message.v = { Simple_sum.v = Sum_type.C "abcd" }; b = 10 }
          ()
      end;

      "lists and arrays" >:: begin fun () ->
        (* 001       tuple, tag 0
         * 018       len
         * 002       nelms
         *  005       htuple, tag 0
         *  006       len
         *  002       nelms
         *   000 020  int(10)
         *   000 128 004 int(256)
         *
         *  005       htuple, tag 0
         *  007       len
         *  003       nlems
         *   000 001   true
         *   000 000   false
         *   000 000   false
         * *)
        check_write
          "\001\018\002\005\006\002\000\020\000\128\004\005\007\003\000\001\000\000\000\000"
          Lists_arrays.write_lists_arrays
          ~msg:"{ Lists_arrays.lint = [10; 256]; abool = [| true; false; false |] }"
          { Lists_arrays.lint = [10; 256]; abool = [| true; false; false |] }
          ()
      end;
    ]

let () =
  Register_test.register "write simple types"
    [
      "bool (true)" >::
        check_write "\001\003\001\000\001"
          Simple_bool.write_simple_bool { Simple_bool.v = true };

      "bool (false)" >::
        check_write "\001\003\001\000\000"
          Simple_bool.write_simple_bool { Simple_bool.v = false };

      "byte" >:: begin fun () ->
        for n = 0 to 127 do
          check_write (sprintf "\001\003\001\000%c" (Char.chr n))
            Simple_byte.write_simple_byte { Simple_byte.v = n } ()
        done;
        for n = 128 to 255 do
          check_write (sprintf "\001\004\001\000%c\001" (Char.chr n))
            Simple_byte.write_simple_byte { Simple_byte.v = n } ()
        done
      end;

      "int" >:: begin fun () ->
        let check n expected =
          check_write ~msg:(sprintf "int %d" n) expected
            Simple_int.write_simple_int { Simple_int.v = n } ()
        in
          check 0 "\001\003\001\000\000";
          for n = 1 to 63 do
            check n (sprintf "\001\003\001\000%c" (Char.chr (2*n)));
            check (-n)
              (sprintf "\001\003\001\000%c" (Char.chr ((2 * lnot (-n)) lor 1)))
          done;
          check 64 "\001\004\001\000\128\001";
          for n = 65 to 8191 do
            check n
              (sprintf "\001\004\001\000%c%c"
                 (Char.chr ((2*n) mod 128 + 128)) (Char.chr ((2*n) / 128)));
            let n' = (2 * lnot (-n)) lor 1 in
              check (-n)
                (sprintf "\001\004\001\000%c%c"
                   (Char.chr (n' mod 128 + 128)) (Char.chr (n' / 128)))
          done
      end;

      "unsigned int" >:: begin fun () ->
        let check n expected =
          check_write ~msg:(sprintf "int %d" n) expected
            Simple_unsigned.write_simple_unsigned { Simple_unsigned.v = n } ()
        in
          for n = 0 to 127 do
            check n (sprintf "\001\003\001\000%c" (Char.chr n));
          done;
          for n = 128 to 16383 do
            check n
              (sprintf "\001\004\001\000%c%c"
                 (Char.chr (n mod 128 + 128)) (Char.chr (n / 128)));
          done
      end;

      "long" >:: begin fun () ->
        let rand_int64 () =
          let upto = match Int64.shift_right_logical (-1L) (8 * Random.int 8) with
              l when l > 0L -> l
            | _ -> Int64.max_int
          in Random.int64 upto in
        let check_long n expected =
          check_write ~msg:(sprintf "long %s" (Int64.to_string n)) expected
            Simple_long.write_simple_long { Simple_long.v = n } ()
        in
          for i = 0 to 10000 do
            let n = rand_int64 () in
              check_bits64 check_long n n
          done;
      end;

      "float" >:: begin fun () ->
        let check_float n expected =
          check_write ~msg:(sprintf "float %f" n) expected
            Simple_float.write_simple_float { Simple_float.v = n } ()
        in
          for i = 0 to 1000 do
            let fl = Random.float max_float -. Random.float max_float in
            let n = Int64.bits_of_float fl in
              check_bits64 check_float fl n
          done
      end;

      "string" >:: begin fun () ->
        let check_string s expected =
          check_write ~msg:(sprintf "string %S" s) expected
            Simple_string.write_simple_string { Simple_string.v = s } ()
        in
          for len = 0 to 124 do
            let s = String.create len in
              check_string s
                (sprintf "\001%c\001\003%c%s" (Char.chr (len + 3)) (Char.chr len) s)
          done;
          let s = String.create 128 in
            check_string s (sprintf "\001\132\001\001\003\128\001%s" s)
      end;

    ]
