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
package org.springframework.samples.petclinic.model;

import java.time.LocalDate;

/**
 * Read-only row of the dashboard's recent visits table. A projection instead of {@link Visit} so that
 * loading it never pulls a pet's eager visit collection: one bounded query, nothing else.
 */
public class VisitSummary {

    private final Integer visitId;
    private final LocalDate date;
    private final String description;
    private final Integer petId;
    private final String petName;
    private final LocalDate petBirthDate;
    private final String petType;
    private final Integer ownerId;
    private final String ownerFirstName;
    private final String ownerLastName;
    private final String ownerTelephone;

    public VisitSummary(Integer visitId, LocalDate date, String description, Integer petId, String petName,
                        LocalDate petBirthDate, String petType, Integer ownerId, String ownerFirstName,
                        String ownerLastName, String ownerTelephone) {
        this.visitId = visitId;
        this.date = date;
        this.description = description;
        this.petId = petId;
        this.petName = petName;
        this.petBirthDate = petBirthDate;
        this.petType = petType;
        this.ownerId = ownerId;
        this.ownerFirstName = ownerFirstName;
        this.ownerLastName = ownerLastName;
        this.ownerTelephone = ownerTelephone;
    }

    public Integer getVisitId() {
        return this.visitId;
    }

    public LocalDate getDate() {
        return this.date;
    }

    public String getDescription() {
        return this.description;
    }

    public Integer getPetId() {
        return this.petId;
    }

    public String getPetName() {
        return this.petName;
    }

    public LocalDate getPetBirthDate() {
        return this.petBirthDate;
    }

    public String getPetType() {
        return this.petType;
    }

    public Integer getOwnerId() {
        return this.ownerId;
    }

    public String getOwnerFirstName() {
        return this.ownerFirstName;
    }

    public String getOwnerLastName() {
        return this.ownerLastName;
    }

    public String getOwnerTelephone() {
        return this.ownerTelephone;
    }

}
