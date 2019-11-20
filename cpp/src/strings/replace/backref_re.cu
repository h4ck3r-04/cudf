/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/null_mask.hpp>
#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/strings/char_types/char_types.hpp>
#include <cudf/strings/replace_re.hpp>
#include "../utilities.hpp"
#include "../utilities.cuh"
#include "../regex/regex.cuh"

#include <regex>

namespace cudf
{
namespace strings
{
namespace detail
{
namespace
{

/**
 * @brief Parse the back-ref index and position values from a given replace format.
 *
 * The backref numbers are expected to be 1-based.
 *
 * Returns a modified string without back-ref indicators.
 * ```
 * Example:
 *    for input string:    'hello \2 and \1'
 *    the returned pairs:  (2,6),(1,11)
 *    returned string is:  'hello  and '
 * ```
 */
std::string parse_backrefs( std::string const& repl, std::vector<thrust::pair<size_type,size_type> >& backrefs )
{
    std::string str = repl; // make a modifiable copy
    std::smatch m;
    std::regex ex("(\\\\\\d+)"); // this searches for backslash-number(s); example "\1"
    std::string rtn;             // result without refs
    size_type byte_offset = 0;
    while( std::regex_search( str, m, ex ) )
    {
        if( m.size()==0 )
            break;
        std::pair<size_type,size_type> item;
        std::string bref = m[0];
        size_type position = static_cast<size_type>(m.position(0));
        size_type length = static_cast<size_type>(bref.length());
        byte_offset += position;
        item.first = std::atoi(bref.c_str()+1); // back-ref index number
        CUDF_EXPECTS( item.first > 0, "Back-reference numbers must be greater than 0");
        item.second = byte_offset;              // position within the string
        rtn += str.substr(0,position);
        str = str.substr(position + length);
        backrefs.push_back(item);
    }
    if( !str.empty() ) // add the remainder
        rtn += str;    // of the string
    return rtn;
}


/**
 * @brief This functor handles replacing strings by applying the compiled regex pattern
 * and inserting the at the backref position indicated in the replacement template.
 *
 * The logic includes computing the size of each string and also writing the output.
 *
 * The stack is used to keep progress on evaluating the regex instructions on each string.
 * So the size of the stack is in proportion to the number of instructions in the given regex pattern.
 *
 * There are three call types based on the number of regex instructions in the given pattern.
 * Small to medium instruction lengths can use the stack effectively though smaller executes faster.
 * Longer patterns require global memory. Shorter patterns are common in data cleaning.
 *
 */
template<size_t stack_size>
struct backrefs_fn
{
    column_device_view const d_strings;
    Reprog_device prog;
    string_view const d_repl;   // string replacement template
    thrust::pair<size_type,size_type>* d_backrefs; // ref/pos pairs
    size_type backref_count;
    const int32_t* d_offsets{}; // these are null when
    char* d_chars{};            // only computing size

    __device__ size_type operator()(size_type idx)
    {
        if( d_strings.is_null(idx) )
            return 0;
        u_char data1[stack_size], data2[stack_size];
        prog.set_stack_mem(data1,data2);
        string_view d_str = d_strings.element<string_view>(idx);
        auto nchars = d_str.length();     // number of characters in input string
        auto nbytes = d_str.size_bytes(); // number of bytes in input string
        const char* in_ptr = d_str.data(); // input pointer (i)
        char* out_ptr = nullptr;  // running output pointer (o)
        if( d_offsets )
            out_ptr = d_chars + d_offsets[idx];
        size_type lpos = 0, begin = 0, end = nchars;  // working vars
        // copy input to output replacing strings as we go
        while( prog.find(idx,d_str,begin,end) > 0 ) // inits the begin/end vars
        {
            auto spos = d_str.byte_offset(begin); // get offset for these
            auto epos = d_str.byte_offset(end);   // character position values
            nbytes += d_repl.size_bytes() - (epos - spos); // compute new size
            if( out_ptr )
                out_ptr = copy_and_increment(out_ptr,in_ptr+lpos,spos-lpos);
            size_type lpos_template = 0;   // last end pos of replace template
            auto repl_ptr = d_repl.data(); // replace template pointer
            for( size_type ridx=0; ridx < backref_count; ++ridx )
            {
                auto backref_index = d_backrefs[ridx].first; // backref number
                if( out_ptr )
                {
                    auto copy_length = d_backrefs[ridx].second - lpos_template;
                    out_ptr = copy_and_increment(out_ptr, repl_ptr, copy_length );
                    repl_ptr += copy_length;
                    lpos_template += copy_length;
                }
                // extract the specific group's string for the backref_index
                size_type spos = begin, epos = end; // these are modified by extract()
                if( (prog.extract(idx,d_str,spos,epos,backref_index-1)<=0 ) ||
                    (epos <= spos) )
                    continue; // no value for this backref number; that is ok
                spos = d_str.byte_offset(spos); // convert
                epos = d_str.byte_offset(epos); // to bytes
                nbytes += epos - spos;
                if( out_ptr )
                    out_ptr = copy_and_increment(out_ptr, d_str.data()+spos, (epos-spos));
            }
            if( out_ptr && (lpos_template < d_repl.size_bytes()) )// copy remainder of template
                out_ptr = copy_and_increment(out_ptr, repl_ptr+lpos_template, d_repl.size_bytes() - lpos_template);
            lpos = epos;
            begin = end;
            end = nchars;
        }
        if( out_ptr && (lpos < d_str.size_bytes()) ) // copy remainder of input string
            memcpy(out_ptr, in_ptr+lpos, d_str.size_bytes()-lpos );
        return nbytes;
    }
};

} // namespace

//
std::unique_ptr<column> replace_with_backrefs( strings_column_view const& strings,
                                               std::string const& pattern,
                                               std::string const& repl,
                                               rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                               cudaStream_t stream = 0)
{
    auto strings_count = strings.size();
    if( strings_count==0 )
        return make_empty_strings_column(mr,stream);

    CUDF_EXPECTS( !pattern.empty(), "Parameter pattern must not be empty");
    CUDF_EXPECTS( !repl.empty(), "Parameter repl must not be empty");

    auto strings_column = column_device_view::create(strings.parent(),stream);
    auto d_strings = *strings_column;
    // compile regex into device object
    auto prog = Reprog_device::create(pattern,get_character_flags_table(),strings_count,stream);
    auto d_prog = *prog;
    auto regex_insts = d_prog.insts_counts();

    // parse the repl string for backref indicators
    std::vector<thrust::pair<size_type,size_type> > h_backrefs;
    std::string repl_template = parse_backrefs(repl,h_backrefs);
    rmm::device_vector<thrust::pair<size_type,size_type> > backrefs(h_backrefs);
    auto d_backrefs = backrefs.data().get();
    size_type backref_count = static_cast<size_type>(backrefs.size());
    //    CUDF_EXPECTS( backref_count == d_prog.group_counts(), "Not all backrefs are accounted by groups");
    string_scalar repl_scalar(repl_template);
    string_view d_repl_template{ repl_scalar.data(), repl_scalar.size() };

    // copy null mask
    auto null_mask = copy_bitmask(strings.parent());
    auto null_count = strings.null_count();

    // create child columns
    std::pair< std::unique_ptr<column>, std::unique_ptr<column> > children(nullptr,nullptr);
    // Each invocation is predicated on the stack size which is dependent on the number of regex instructions
    if( (regex_insts > MAX_STACK_INSTS) || (regex_insts <= RX_SMALL_INSTS) )
        children = make_strings_children(backrefs_fn<RX_STACK_SMALL>{d_strings,d_prog,d_repl_template,d_backrefs,backref_count},
                                         strings_count, null_count, mr, stream);
    else if( regex_insts <= RX_MEDIUM_INSTS )
        children = make_strings_children(backrefs_fn<RX_STACK_MEDIUM>{d_strings,d_prog,d_repl_template,d_backrefs,backref_count},
                                         strings_count, null_count, mr, stream);
    else
        children = make_strings_children(backrefs_fn<RX_STACK_LARGE>{d_strings,d_prog,d_repl_template,d_backrefs,backref_count},
                                         strings_count, null_count, mr, stream);
    //
    return make_strings_column(strings_count, std::move(children.first), std::move(children.second),
                               null_count, std::move(null_mask), stream, mr);
}

} // namespace detail

// external API

std::unique_ptr<column> replace_with_backrefs( strings_column_view const& strings,
                                               std::string const& pattern,
                                               std::string const& repl,
                                               rmm::mr::device_memory_resource* mr )
{
    return detail::replace_with_backrefs(strings, pattern, repl, mr);
}

} // namespace strings
} // namespace cudf
