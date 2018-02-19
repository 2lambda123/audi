#ifndef AUDI_INVERT_MAP_HPP
#define AUDI_INVERT_MAP_HPP

#include <Eigen/Dense>
#include <algorithm>
#include <stdexcept>
#include <string>
#include <vector>

#include <audi/audi.hpp>
#include <audi/exceptions.hpp>
#include <audi/io.hpp>

namespace audi
{
// The basic type of a Taylor map, that is a "square" collection of gduals
using taylor_map = std::vector<gdual_d>;

namespace detail
{
// This is the composition operator.
taylor_map operator&(const taylor_map &A, const taylor_map &B)
{
    taylor_map retval;
    auto ss = A[0].get_symbol_set();
    for (decltype(A.size()) i = 0u; i < A.size(); ++i) {
        auto tmp = A[i];
        for (decltype(B.size()) j = 0u; j < B.size(); ++j) {
            tmp = tmp.subs("d" + ss[j], B[j]);
        }
        retval.push_back(tmp);
    }
    return retval;
}

// This is the sum operator.
taylor_map operator+(const taylor_map &A, const taylor_map &B)
{
    taylor_map retval(B.size());
    for (decltype(B.size()) i = 0u; i < B.size(); ++i) {
        retval[i] = A[i] + B[i];
    }
    return retval;
}

// This is the diff operator.
taylor_map operator-(const taylor_map &A, const taylor_map &B)
{
    taylor_map retval(B.size());
    for (decltype(B.size()) i = 0u; i < B.size(); ++i) {
        retval[i] = A[i] - B[i];
    }
    return retval;
}

// This is the "multiplication" operator.
template <typename T>
taylor_map operator*(const T &c, const taylor_map &A)
{
    taylor_map retval(A.size());
    for (decltype(A.size()) i = 0u; i < A.size(); ++i) {
        retval[i] = A[i] * c;
    }
    return retval;
}

taylor_map trim(const taylor_map &A, double epsilon)
{
    taylor_map retval(A.size());
    for (decltype(A.size()) i = 0u; i < A.size(); ++i) {
        retval[i] = A[i].trim(epsilon);
    }
    return retval;
}

// Eigen stores indexes and sizes as signed types, while audi
// uses STL containers thus sizes and indexes are unsigned. To
// make the conversion as painless as possible this template is provided
// allowing, for example, syntax of the type M[_(i)] to adress an element
// of a vector when i is an Eigen::DenseIndex
template <typename I>
static unsigned _(I n)
{
    return static_cast<unsigned>(n);
}

} // ends detail

/// Inversion of Taylor maps
/**
 * This function inverts a Taylor map \f$ \mathcal M \f$, that is a polynomial map \f$n \rightarrow n\f$
 * The inverse will have the property:
 * \f[
 * \mathcal M^{-1} \circ (M + N) = \mathcal I
 * \f]
 *
 * where we have written the map \f$\mathcal M = C + M + N\f$ as the sum of its constant part, its linear part
 * and the rest.
 *
 */
taylor_map invert_map(const taylor_map &map_in)
{
    // To find the overloaded operators
    using namespace detail;
    // Some preliminary definitions and consistency checks
    // The map cannot be empty
    auto map_size = map_in.size();
    if (map_size == 0) {
        audi_throw(std::invalid_argument, "Impossible to invert the Tayor Map as it is empty!");
    }
    // The map has to contain equal order gduals. (We could allow for different order implementing some promotion)
    auto map_order = map_in[0].get_order();
    if (!std::all_of(map_in.cbegin(), map_in.cend(),
                     [&map_order](const gdual_d &el) { return (el.get_order() == map_order); })) {
        audi_throw(std::invalid_argument,
                   "Impossible to invert the Tayor Map as the order of its components are mismatching.");
    }
    // The map needs to contain gdual having the same symbols. (We could allow different symbols and take the union)
    auto ss = map_in[0].get_symbol_set();
    if (!std::all_of(map_in.cbegin(), map_in.cend(),
                     [&ss](const gdual_d &el) { return (el.get_symbol_set() == ss); })) {
        audi_throw(std::invalid_argument,
                   "Impossible to invert the Tayor Map as the symbol sets of its components are mismatching.");
    }
    // The map must be "square"
    if (ss.size() != map_size) {
        audi_throw(std::invalid_argument,
                   "Impossible to invert the Tayor Map as the number of symbols is not the same as the map size.");
    }
    // We add the differential symbol to the variable symbols
    for (auto &s : ss) {
        s = "d" + s;
    }
    std::vector<std::string> ss_inv;
    for (decltype(map_size) i = 0u; i < map_size; ++i) {
        ss_inv.push_back("dp" + std::to_string(i));
    }
    /// ---------------------- Algorithm Start ---------------------------------------///
    // We decompose the map as map = M + N (linear plus non linear part). The inverse of the linear part will be Minv
    taylor_map M(map_size, gdual_d(0)), Minv(map_size, gdual_d(0)), N(map_size, gdual_d(0)), I(map_size, gdual_d(0)),
        Minv2(map_size, gdual_d(0));
    taylor_map retval;

    // We construct the identity map [p0, p1, p2, ... ]
    for (decltype(map_size) i = 0u; i < map_size; ++i) {
        I[i] = gdual_d(0., "p" + std::to_string(i), map_order);
        I[i].extend_symbol_set(ss_inv);
    }

    // Populate M, the linear part of the map
    for (decltype(map_size) i = 0u; i < map_size; ++i) {
        M[i] = map_in[i].extract_terms(1);
        M[i].extend_symbol_set(ss);
    }

    // Populate N, the non linear part of the map
    for (decltype(map_size) i = 0u; i < map_size; ++i) {
        for (decltype(map_order) j = 2u; j <= map_order; ++j) {
            N[i] = N[i] + map_in[i].extract_terms(j);
        }
        N[i].extend_symbol_set(ss);
    }

    // Invert M (using eigen)
    using namespace Eigen;
    MatrixXd mat(map_size, map_size);
    for (decltype(mat.rows()) i = 0u; i < mat.rows(); ++i) {
        for (decltype(mat.rows()) j = 0u; j < mat.cols(); ++j) {
            std::vector<unsigned> monomial(map_size, 0u);
            monomial[_(j)] = 1u;
            mat(i, j) = M[_(i)].find_cf(monomial);
        }
    }
    auto det = mat.determinant();
    if (std::abs(det) < 1e-10) {
        audi_throw(std::invalid_argument,
                   "The map you are trying to invert has a non ivertable linear part, its determinant is: "
                       + std::to_string(det));
    }
    auto invm = mat.inverse();

    // Populate Minv and Minv2 the inverse of the linear part (they are the same map, only with different
    // symbols to avoid mess when subs symbols later)
    for (decltype(invm.rows()) i = 0; i < invm.rows(); ++i) {
        for (decltype(invm.cols()) j = 0; j < invm.cols(); ++j) {
            gdual_d dummy(0., "p" + std::to_string(j), map_order);
            gdual_d dummy2(0., "pdummy" + std::to_string(j), map_order);
            dummy *= invm(i, j);
            dummy2 *= invm(i, j);
            // this must have the same symbols of the identity and the final symbols of the onverse map returned
            Minv[_(i)] += dummy;
            // this must have different symbols as to avoid mess when calling subs (in the & operator)
            Minv2[_(i)] += dummy2;
        }
    }

    retval = Minv;
    // Picard Iterations (each iteration will increase the order by one)
    for (decltype(map_order) i = 0u; i < map_order; ++i) {
        retval = (I - (N & retval));
        retval = Minv2 & retval;
    }

    return retval;
}

} // end of namespace audi

#endif
