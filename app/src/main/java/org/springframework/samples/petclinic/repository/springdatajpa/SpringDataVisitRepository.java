/*
 * Copyright 2002-2022 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.springframework.samples.petclinic.repository.springdatajpa;

import java.util.List;

import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.Repository;
import org.springframework.samples.petclinic.model.Visit;
import org.springframework.samples.petclinic.model.VisitSummary;
import org.springframework.samples.petclinic.repository.VisitRepository;

/**
 * Spring Data JPA specialization of the {@link VisitRepository} interface
 *
 * @author Michael Isvy
 * @since 15.1.2013
 */
public interface SpringDataVisitRepository extends VisitRepository, Repository<Visit, Integer> {

    @Override
    @Query("SELECT count(visit) FROM Visit visit")
    long countVisits();

    @Override
    default List<VisitSummary> findRecentVisits(int limit) {
        return findRecent(PageRequest.of(0, limit));
    }

    @Query("SELECT new org.springframework.samples.petclinic.model.VisitSummary(visit.id, visit.date, visit.description, pet.id, pet.name, pet.birthDate, type.name, owner.id, owner.firstName, owner.lastName, owner.telephone) FROM Visit visit JOIN visit.pet pet JOIN pet.type type JOIN pet.owner owner ORDER BY visit.date DESC, visit.id DESC")
    List<VisitSummary> findRecent(Pageable pageable);
}
